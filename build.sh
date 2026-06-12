#!/bin/sh
set -eu

# -----------------------
# Environment
# -----------------------

cwd="$(pwd -P)"
log() { echo "$(date '+%H:%M:%S') [BUILD] $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Root required"
  exit 1
fi

# -----------------------
# Defaults
# -----------------------

desktop="plasma"
build_type="release"

label="FreeBSD"

workdir="${workdir:-/usr/local/freebsd-build}"

# -----------------------
# Static config (no find hacks)
# -----------------------

DESKTOPS="plasma xfce mate kde"

# -----------------------
# Help
# -----------------------

help() {
  echo "Usage: $0 -d desktop -b build_type"
  echo ""
  echo "Desktops: ${DESKTOPS}"
  echo "Build types: release testing unstable"
  exit 1
}

# -----------------------
# Args
# -----------------------

while getopts "d:b:h" opt; do
  case "$opt" in
    d) desktop="$OPTARG" ;;
    b) build_type="$OPTARG" ;;
    h) help ;;
    *) help ;;
  esac
done

# -----------------------
# Validation (clean)
# -----------------------

case "${build_type}" in
  release|testing|unstable) ;;
  *) echo "Invalid build_type"; exit 1 ;;
esac

case "${desktop}" in
  ${DESKTOPS%% *}|*) ;;
  *)
    echo "Invalid desktop: ${desktop}"
    echo "Valid: ${DESKTOPS}"
    exit 1
    ;;
esac

# -----------------------
# Derived values (clean naming)
# -----------------------

community=""
case "${desktop}" in
  plasma|xfce|mate|kde)
    community="-${desktop}"
    ;;
esac

release_dir="${workdir}/release"
iso_dir="${workdir}/iso"
pkg_dir="${workdir}/packages"
cd_root="${workdir}/cdroot"

label_full="${label}-${build_type}${community}"

log "Build started: ${label_full}"

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

freebsd_config()
{
  log "Applying system configuration..."

  # Desktop profile marker (generic, not GhostBSD)
  mkdir -p "${release}/usr/local/share/desktop"
  echo "${desktop}" > "${release}/usr/local/share/desktop/current"

  # Linux compatibility filesystem (optional layer)
  chroot "${release}" mkdir -p /compat/linux/dev/shm
  chroot "${release}" mkdir -p /compat/linux/proc
  chroot "${release}" mkdir -p /compat/linux/sys

  # Boot entropy seed (optional, harmless legacy compatibility)
  chroot "${release}" touch /boot/entropy || true

  # Clock behavior (ONLY if you want Windows dual boot friendliness)
  # chroot "${release}" touch /etc/wall_cmos_clock

  log "System configuration complete"
}

desktop_config()
{
  log "Applying desktop-specific configuration (${desktop})..."
  # run config for GhostBSD flavor
  sh "${cwd}/desktop_config/${desktop}.sh"
}

uzip_fs()
{
  log "Creating ZFS root snapshot image..."

  dataset="${1:-freebsd}"
  snap="${dataset}@clean"

  if ! zfs list "${dataset}" >/dev/null 2>&1; then
    log "ERROR: dataset ${dataset} not found"
    return 1
  fi

  # create snapshot safely
  zfs snapshot -r "${snap}"

  install -o root -g wheel -d "${cd_root}/data"

  output="${cd_root}/data/system.zfs"

  # export snapshot
  zfs send -R -c "${snap}" > "${output}"

  log "ZFS image created at: ${output}"
}

ramdisk()
{
  log "Creating ramdisk image..."

  ramdisk_root="${cd_root}/data/ramdisk"
  mkdir -p "${ramdisk_root}"

  # safer copy of rescue
  (cd "${release}" && tar -cf - rescue) | tar -xf - -C "${ramdisk_root}"

  # init script (no branding)
  sed "s/@VOLUME@/FREEBSD-LIVE/" init.sh.in > "${ramdisk_root}/init.sh"
  chmod 755 "${ramdisk_root}/init.sh"

  # minimal filesystem structure
  mkdir -p "${ramdisk_root}/dev"
  mkdir -p "${ramdisk_root}/etc"
  touch "${ramdisk_root}/etc/fstab"

  install -o root -g wheel -m 755 rc.in "${ramdisk_root}/etc/rc"

  cp "${release}/etc/login.conf" "${ramdisk_root}/etc/login.conf"

  # create filesystem image
  makefs -b 10% "${cd_root}/data/ramdisk.ufs" "${ramdisk_root}"

  gzip -f "${cd_root}/data/ramdisk.ufs"

  rm -rf "${ramdisk_root}"

  log "ramdisk created successfully"
}

boot()
{
  log "Preparing boot files..."

  cd "${release}"

  # safer boot copy (no duplication)
  tar -cf - boot | tar -xf - -C "${cd_root}"

  cp COPYRIGHT "${cd_root}/COPYRIGHT"
  cp "${cwd}/LICENSE" "${cd_root}/LICENSE"

  mkdir -p "${cd_root}/etc"

  # cleanup mounts safely
  if mount | grep -q "${release}/dev"; then
    umount "${release}/dev" || log "Warning: dev unmount failed"
  fi

  if mount | grep -q "${release}"; then
    umount "${release}" || log "Warning: release unmount failed"
  fi

  # ZFS export (parameterized)
  zpool_name="${zpool_name:-ghostbsd}"

  zpool export "${zpool_name}" || {
    log "ERROR: failed to export zpool ${zpool_name}"
    return 1
  }

  # wait loop with timeout
  timeout=10
  while zpool list "${zpool_name}" >/dev/null 2>&1; do
    sleep 1
    timeout=$((timeout - 1))

    if [ "${timeout}" -le 0 ]; then
      log "ERROR: timeout exporting zpool ${zpool_name}"
      break
    fi
  done

  log "Boot preparation complete"
}

build_image()
{
  log "Creating ISO image..."

  cd script || return 1

  sh mkisoimages.sh -b "${label}" "${iso_path}" "${cd_root}" || {
    log "ERROR: ISO build failed"
    return 1
  }

  cd - >/dev/null

  ls -lh "${iso_path}"

  cd "${iso}" || return 1

  iso_file="$(basename "${iso_path}")"

  log "Creating SHA256..."

  sha256 "${iso_file}" > "${iso_file}.sha256"

  log "SHA256 generated: ${iso_file}.sha256"

  cd - >/dev/null
}

workspace
base
set_freebsd_version
packages_software
fetch_x_drivers_packages
rc
desktop_config
freebsd_config
uzip_fs
ramdisk
boot
build_image
