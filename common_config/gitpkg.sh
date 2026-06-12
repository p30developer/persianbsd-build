#!/bin/sh

set -e -u

git_pc_sysinstall()
{
  git clone https://github.com/freebsd/pc-sysinstall.git \
    "${release}/pc-sysinstall"

  chroot "${release}" sh -c '
    cd /pc-sysinstall && sh install.sh
  '

  rm -rf "${release}/pc-sysinstall"
}
