#!/bin/sh

set -e -u

final_setup()
{
  # keep backup but remove branding
  cp "${release}/etc/rc.conf" "${release}/etc/rc.conf.bak"

  # enable wheel sudo
  sed -i "" -e 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/g' \
    "${release}/usr/local/etc/sudoers"

  # optional: ensure sudo group exists (safe guard)
  pw groupadd sudo 2>/dev/null || true
}
