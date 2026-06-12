#!/usr/bin/env sh

set -e -u

cwd="$(realpath)"
export cwd

# Enhanced logging function
log() {
    echo "$(date '+%H:%M:%S') [BUILD] $*"
}

# Only run as superuser
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

# Use find to locate base files and extract filenames directly, converting newlines to spaces
desktop_list=$(find packages -type f ! -name '*base*' ! -name '*common*' ! -name '*drivers*' -exec basename {} \; | sort -u | tr '\n' ' ')

# Find all files in the desktop_config directory
desktop_config_list=$(find desktop_config -type f)
help_function()
{
  printf "Usage: %s -d desktop -b build_type\n" "$0"
  printf "\t-h for help\n"
  printf "\t-d Desktop: %s\n" "${desktop_list}"
  printf "\t-b Build type: unstable, testing, or release\n"
   exit 1 # Exit script after printing help
}
# Set mate and release to be default
export desktop="plasma"
export build_type="release"

while getopts "d:b:h" opt
do
   case "$opt" in
      'd') export desktop="$OPTARG" ;;
      'b') export build_type="$OPTARG" ;;
      'h') help_function ;;
      '?') help_function ;;
      *) help_function ;;
   esac
done

if [ "${build_type}" = "testing" ] ; then
  PKG_CONF="GhostBSD_Testing"
elif [ "${build_type}" = "release" ] ; then
  PKG_CONF="GhostBSD"
elif [ "${build_type}" = "unstable" ] ; then
  PKG_CONF="GhostBSD_Unstable"
else
  printf "\t-b Build type: unstable, testing, or release\n"
  exit 1
fi

# validate desktop packages
if [ ! -f "${cwd}/packages/${desktop}" ] ; then
  echo "The packages/${desktop} file does not exist."
  echo "Please create a package file named '${desktop}'and place it under packages/."
  echo "Or use a valid desktop below:"
  echo "$desktop_list"
  echo "Usage: ./build.sh -d desktop"
  exit 1
fi

# validate desktop
if [ ! -f "${cwd}/desktop_config/${desktop}.sh" ] ; then
  echo "The desktop_config/${desktop}.sh file does not exist."
  echo "Please create a config file named '${desktop}.sh' like these config:"
  echo "$desktop_config_list"
  exit 1
fi

if [ "${desktop}" != "mate" ] ; then
  DESKTOP=$(echo "${desktop}" | tr '[:lower:]' '[:upper:]')
  community="-${DESKTOP}"
else
  community=""
fi

workdir="/var/local"
livecd="${workdir}/freebsd-build"
base="${livecd}/base"
iso="${livecd}/iso"
packages_storage="${livecd}/packages"
release="${livecd}/release"
export release
cd_root="${livecd}/cd_root"
live_user="freebsd"
export live_user

time_stamp=""
release_stamp=""
label="FreeBSD"

workspace()
{
  log "Setting up workspace and cleaning previous builds..."

  # Cleanup previous mounts
  umount -f ${packages_storage} >/dev/null 2>/dev/null || true
  umount -f ${release}/dev >/dev/null 2>/dev/null || true
  umount -f ${release} >/dev/null 2>/dev/null || true

  # Cleanup old zpool
  zpool destroy persianbsd >/dev/null 2>/dev/null || true

  # Remove previous cd_root
  if [ -d "${cd_root}" ]; then
    chflags -R noschg ${cd_root} 2>/dev/null || true
    rm -rf ${cd_root}
  fi

  # Detach old memory disk
  mdconfig -d -u 0 >/dev/null 2>/dev/null || true

  # Remove previous pool image
  rm -f ${livecd}/pool.img

  # Create workspace
  mkdir -p \
    ${livecd} \
    ${base} \
    ${iso} \
    ${packages_storage} \
    ${release}

  # ZFS image size
  POOL_SIZE="6g"

  truncate -s ${POOL_SIZE} ${livecd}/pool.img

  # Attach image as md device
  mdconfig -f ${livecd}/pool.img -u 0

  # Create build pool
  if ! zpool create \
      -O mountpoint="${release}" \
      -O compression=zstd-9 \
      persianbsd \
      /dev/md0
  then
      echo "ERROR: unable to create build pool"

      zpool destroy persianbsd 2>/dev/null || true
      mdconfig -d -u 0 2>/dev/null || true
      rm -f ${livecd}/pool.img

      exit 1
  fi
}

base()
{
  log "Installing base system packages..."

  base_list="$(cat "${cwd}/packages/base")"

  mkdir -p ${release}/etc
  cp /etc/resolv.conf ${release}/etc/resolv.conf

  mkdir -p ${release}/var/cache/pkg
  mount_nullfs ${packages_storage} ${release}/var/cache/pkg

  pkg -r ${release} bootstrap -f
  pkg -r ${release} install -y ${base_list}

  rm -f ${release}/etc/resolv.conf

  umount ${release}/var/cache/pkg

  touch ${release}/etc/fstab

  mkdir -p \
      ${release}/cdrom \
      ${release}/mnt \
      ${release}/media
}

set_freebsd_version()
{
  log "Setting system version..."

  version_file="${release}/etc/version"

  if [ ! -f "${version_file}" ]; then
    log "ERROR: version file not found: ${version_file}"
    return 1
  fi

  base_version="$(cat "${version_file}")"

  if [ "${build_type}" = "testing" ] || [ "${build_type}" = "unstable" ]; then
    date_suffix="$(date +%Y%m%d-%H%M)"
    version="${base_version}-${build_type}${date_suffix}"
    log "Testing/unstable build: ${version}"
  else
    version="${base_version}"
  fi

  iso_path="${iso}/${label}-${version}-${release_stamp}-${time_stamp}${community}.iso"

  log "ISO path set to: ${iso_path}"
}


packages_software()
{
  log "Installing desktop packages (${desktop})..."

  pkg_conf="${release}/etc/pkg/FreeBSD.conf"

  if [ "${build_type}" = "unstable" ]; then
    cp pkg/FreeBSD_Unstable.conf "${pkg_conf}"
  elif [ "${build_type}" = "testing" ]; then
    cp pkg/FreeBSD_Testing.conf "${pkg_conf}"
  else
    cp pkg/FreeBSD_Release.conf "${pkg_conf}"
  fi

  mkdir -p "${release}/etc"
  echo "nameserver 1.1.1.1" > "${release}/etc/resolv.conf"

  mkdir -p "${release}/var/cache/pkg"
  mount_nullfs "${packages_storage}" "${release}/var/cache/pkg"

  mount -t devfs devfs "${release}/dev"

  de_packages=$(tr '\n' ' ' < "${cwd}/packages/${desktop}")
  common_packages=$(tr '\n' ' ' < "${cwd}/packages/common")
  drivers_packages=$(tr '\n' ' ' < "${cwd}/packages/drivers")

  vital_de_packages=$(tr '\n' ' ' < "${cwd}/packages/vital/${desktop}")
  vital_common_packages=$(tr '\n' ' ' < "${cwd}/packages/vital/common")

  pkg -c "${release}" update -f

  pkg -c "${release}" install -y \
    ${de_packages} \
    ${common_packages} \
    ${drivers_packages}

  pkg -c "${release}" set -y -v 1 \
    ${vital_de_packages} \
    ${vital_common_packages}

  rm -f "${release}/etc/resolv.conf"

  umount "${release}/var/cache/pkg" || true
  umount "${release}/dev" || true
}


fetch_x_drivers_packages()
{
  log "Fetching X drivers packages..."

  case "${build_type}" in
    release)
      repo_type="stable"
      ;;
    testing)
      repo_type="testing"
      ;;
    *)
      repo_type="unstable"
      ;;
  esac

  mkdir -p "${release}/xdrivers"

  # update repo metadata (safe way)
  pkg -c "${release}" update -f

  # query packages once
  pkg_list=$(pkg -c "${release}" rquery -x \
    '%n-%v' \
    'xlibre-nvidia-driver|nvidia-kmod|egl-x11' \
    | grep -v -E 'libva|304|devel')

  echo "${pkg_list}" > "${release}/xdrivers/drivers-list"

  # instead of manual fetch → use pkg fetch (correct tool)
  for pkgname in ${pkg_list}; do
    pkg -c "${release}" fetch -y -o "${release}/xdrivers" "${pkgname}"
  done

  ls -lah "${release}/xdrivers"
}

rc()
{
  log "Configuring rc settings..."

  chroot "${release}" sysrc hostname="livecd"

  # Core system services
  chroot "${release}" sysrc devfs_enable="YES"
  chroot "${release}" sysrc devfs_system_ruleset="devfsrules_common"

  chroot "${release}" sysrc zfs_enable="YES"

  # Optional compatibility layer (not forced)
  chroot "${release}" sysrc linux_enable="YES"
  chroot "${release}" sysrc kld_list="linux linux64 cuse fusefs"

  # Desktop services (profile-based, not base)
  chroot "${release}" sysrc dbus_enable="YES"
  chroot "${release}" sysrc moused_enable="YES"

  # Printing / discovery
  chroot "${release}" sysrc cupsd_enable="YES"
  chroot "${release}" sysrc avahi_daemon_enable="YES"
  chroot "${release}" sysrc avahi_dnsconfd_enable="YES"

  # Time sync (modern safe default)
  chroot "${release}" sysrc ntpd_enable="YES"

  # Security
  chroot "${release}" sysrc firewall_enable="YES"
  chroot "${release}" sysrc firewall_type="workstation"

  # Cleanup
  chroot "${release}" sysrc clear_tmp_enable="YES"

  log "rc configuration complete"
}

ghostbsd_config()
{
  log "Applying GhostBSD configuration..."
  # echo "gop set 0" >> ${release}/boot/loader.rc.local
  mkdir -p ${release}/usr/local/share/ghostbsd
  echo "${desktop}" > ${release}/usr/local/share/ghostbsd/desktop
  # Mkdir for linux compat to ensure /etc/fstab can mount when booting LiveCD
  chroot ${release} mkdir -p /compat/linux/dev/shm
  chroot ${release} mkdir -p /compat/linux/proc
  chroot ${release} mkdir -p /compat/linux/sys
  # Add /boot/entropy file
  chroot ${release} touch /boot/entropy
  # default GhostBSD to local time instead of UTC
  chroot ${release} touch /etc/wall_cmos_clock
}

desktop_config()
{
  log "Applying desktop-specific configuration (${desktop})..."
  # run config for GhostBSD flavor
  sh "${cwd}/desktop_config/${desktop}.sh"
}

uzip()
{
  log "Creating compressed uzip filesystem..."
  install -o root -g wheel -m 755 -d "${cd_root}"
  mkdir "${cd_root}/data"
  zfs snapshot ghostbsd@clean
  zfs send -p -c -e ghostbsd@clean | dd of=/usr/local/ghostbsd-build/cd_root/data/system.img status=progress bs=1M
}

ramdisk()
{
  log "Creating ramdisk..."
  ramdisk_root="${cd_root}/data/ramdisk"
  mkdir -p "${ramdisk_root}"
  cd "${release}"
  tar -cf - rescue | tar -xf - -C "${ramdisk_root}"
  cd "${cwd}"
  install -o root -g wheel -m 755 "init.sh.in" "${ramdisk_root}/init.sh"
  sed "s/@VOLUME@/GHOSTBSD/" "init.sh.in" > "${ramdisk_root}/init.sh"
  mkdir "${ramdisk_root}/dev"
  mkdir "${ramdisk_root}/etc"
  touch "${ramdisk_root}/etc/fstab"
  install -o root -g wheel -m 755 "rc.in" "${ramdisk_root}/etc/rc"
  cp ${release}/etc/login.conf ${ramdisk_root}/etc/login.conf
  makefs -b '10%' "${cd_root}/data/ramdisk.ufs" "${ramdisk_root}"
  gzip "${cd_root}/data/ramdisk.ufs"
  rm -rf "${ramdisk_root}"
}

boot()
{
  log "Preparing boot files..."
  cd "${release}"
  tar -cf - boot | tar -xf - -C "${cd_root}"
  cp COPYRIGHT ${cd_root}/COPYRIGHT
  cd "${cwd}"
  cp LICENSE ${cd_root}/LICENSE
  cp -R boot/ ${cd_root}/boot/
  mkdir ${cd_root}/etc

  # Try to unmount dev and release if mounted
  umount ${release}/dev >/dev/null 2>/dev/null || true
  umount ${release} >/dev/null 2>/dev/null || true
  
  # Export ZFS pool and ensure it's clean
  zpool export ghostbsd
  timeout=10
  while zpool status ghostbsd >/dev/null 2>&1; do
    sleep 1
    timeout=$((timeout - 1))
    if [ $timeout -eq 0 ]; then
      echo "Failed to cleanly export ZFS pool within timeout"
      break
    fi
  done
}

image()
{
  log "Creating ISO image..."
  cd script
  sh mkisoimages.sh -b $label "$iso_path" ${cd_root}
  cd -
  ls -lh "$iso_path"
  cd ${iso}
  shafile=$(echo "${iso_path}" | cut -d / -f6).sha256
  torrent=$(echo "${iso_path}" | cut -d / -f6).torrent
  tracker1="http://tracker.openbittorrent.com:80/announce"
  tracker2="udp://tracker.opentrackr.org:1337"
  tracker3="udp://tracker.coppersurfer.tk:6969"
  echo "Creating sha256 \"${iso}/${shafile}\""
  sha256 "$(echo "${iso_path}" | cut -d / -f6)" > "${iso}/${shafile}"
  transmission-create -o "${iso}/${torrent}" -t ${tracker1} -t ${tracker2} -t ${tracker3} "${iso_path}"
  chmod 644 "${iso}/${torrent}"
  cd -
}

workspace
base
set_freebsd_version
packages_software
fetch_x_drivers_packages
rc
desktop_config
ghostbsd_config
uzip
ramdisk
boot
image
