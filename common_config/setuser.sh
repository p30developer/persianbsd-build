#!/bin/sh

set -e -u

set_user()
{
  chroot "${release}" pw useradd "${live_user}" -u 1100 \
  -c "Live User" -d "/home/${live_user}" \
  -g wheel -G operator -m -s /usr/local/bin/zsh -k /usr/share/skel -w none
}

set_liveuser()
{
  set_user

  chroot "${release}" su "${live_user}" -c "mkdir -p /home/${live_user}/.config/gtk-3.0"

  cat > "${release}/home/${live_user}/.config/gtk-3.0/settings.ini" <<EOF
[Settings]
gtk-application-prefer-dark-theme = false
gtk-theme-name = Adwaita
gtk-icon-theme-name = Adwaita
gtk-font-name = Sans 11
EOF

  mkdir -p "${release}/root/.config/gtk-3.0"
  cp "${release}/home/${live_user}/.config/gtk-3.0/settings.ini" \
     "${release}/root/.config/gtk-3.0/settings.ini"
}
