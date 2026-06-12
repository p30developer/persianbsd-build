#!/bin/sh

set -e -u

. "${cwd}/common_config/autologin.sh"
. "${cwd}/common_config/base-setting.sh"
. "${cwd}/common_config/finalize.sh"
. "${cwd}/common_config/setuser.sh"

lightdm_setup()
{
  sed -i '' 's@#greeter-session=.*@greeter-session=slick-greeter@' \
    "${release}/usr/local/etc/lightdm/lightdm.conf"

  sed -i '' 's@#user-session=.*@user-session=xfce@' \
    "${release}/usr/local/etc/lightdm/lightdm.conf"
}

setup_xinit()
{
  chroot "${release}" su "${live_user}" -c "echo 'exec startxfce4' > /home/${live_user}/.xinitrc"
  echo 'exec startxfce4' > "${release}/root/.xinitrc"
  echo 'exec startxfce4' > "${release}/usr/share/skel/dot.xinitrc"
}

patch_etc_files
patch_loader_conf_d
lightdm_setup
setup_xinit
final_setup
