#!/bin/sh
set -e

. install-boot.sh

MAKEFS=${MAKEFS:-makefs}
MKIMG=${MKIMG:-mkimg}
ETDUMP=${ETDUMP:-etdump}

if [ "$1" = "-b" ]; then
    BASEDIR="$4"

    bootopt="-o bootimage=i386;${BASEDIR}/boot/cdboot -o no-emul-boot"

    esp=$(mktemp /tmp/efi.XXXXXX)
    make_esp_file "$esp" 2048 "${BASEDIR}/boot/loader.efi"

    bootopt="$bootopt -o bootimage=i386;${esp} -o no-emul-boot -o platformid=efi"

    shift
else
    BASEDIR="$3"
    bootopt=""
fi

LABEL=$(echo "$1" | tr '[:lower:]' '[:upper:]')
NAME="$2"

echo "/dev/iso9660/$LABEL / cd9660 ro 0 0" > "${BASEDIR}/etc/fstab"

$MAKEFS -t cd9660 $bootopt \
  -o rockridge \
  -o label="$LABEL" \
  "$NAME" "$@"

rm -f "${BASEDIR}/etc/fstab"
rm -f "$esp"

# optional hybrid GPT (USB boot)
if [ -n "$bootopt" ]; then
    imgsize=$(stat -f %z "$NAME")

    $MKIMG -s gpt \
      --capacity $imgsize \
      -b "${BASEDIR}/boot/pmbr" \
      -p freebsd-boot:="${BASEDIR}/boot/isoboot" \
      -o hybrid.img

    dd if=hybrid.img of="$NAME" bs=32k count=1 conv=notrunc
    rm -f hybrid.img
fi
