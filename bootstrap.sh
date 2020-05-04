#!/usr/bin/env bash
# vim: set tabstop=4 softtabstop=0 expandtab shiftwidth=4 smarttab:
set -euo pipefail
set -x

# shows a dialog (duh) asking for confirmation. It contains a red \Z1 bold \Zb warning. The warning is set back at \Zn.
# the size is determined automatically (0 0)
dialog --clear \
    --colors \
    --yesno \
    --defaultno \
    'Lets choose a destination disk. It will be used whole!\n\Z1\ZbExisting partitions will be removed!\Zn\n\nDo you want to continue?' \
    0 0
declare -i _dialog_return="$?"
if ((_dialog_return != 0)); then
    [[ "$0" == "${BASH_SOURCE[0]}" ]] && exit 1 || return 1 # handle exits from shell or function but don't exit interactive shell
fi

declare -a _DISK_CHOOSE_OPTIONS=()
while read -r _disk_type _disk_size _disk_path; do
    if [[ "$_disk_type" == 'disk' ]]; then
        _DISK_CHOOSE_OPTIONS+=("$_disk_path" "Size: $_disk_size")
    fi
done < <(lsblk -o TYPE,SIZE,PATH --noheadings)

# open an additional file descriptor (fd3) to allow usage of dialog inside the subshell and redirecting its output
exec 3>&1
_DESTINATION_DISK=$(dialog --clear \
    --backtitle "Choose a disk to write to" \
    --title "Choose a disk to write to" \
    --menu "Available disks" 15 40 4 \
    "${_DISK_CHOOSE_OPTIONS[@]}" \
    2>&1 1>&3)
# close the additional fd
exec 3>&-

declare -r DEST_DISK_PATH="${_DESTINATION_DISK}"
#declare -r PACKAGELIST="sudo,popularity-contest"
declare -r DEST_CHROOT_DIR="/mnt/tmp"

mkdir -p "${DEST_CHROOT_DIR}"

# partition disk
# clear partition table
sgdisk --zap-all "${DEST_DISK_PATH}"
# UEFI - could also be 512M, discuss
sgdisk -n1:1M:+1G -t1:EF00 -c 1:efi "${DEST_DISK_PATH}"
# root (minus 4 GiB for swap
sgdisk -n2:0:-4G -t2:8309 -c 2:crypt-root "${DEST_DISK_PATH}"
# swap
sgdisk -n3:0:0 -t3:8309 -c 3:crypt-swap "${DEST_DISK_PATH}"
# update partition table
partprobe
sleep 5

# setup disk encryption
echo "Setting up disk encryption, please enter a proper passphrase next."
# root, use longer time to do PBKDF2 passphrase processing
cryptsetup --iter-time 5000 luksFormat "${DEST_DISK_PATH}2"
# swap
# FIXME setup key file in created FS later... of use $something more simple
#cryptsetup open --type plain <device> <dmname>

# open crypto container
echo "Enter above passphrase again to open cryptoroot"
cryptsetup open "${DEST_DISK_PATH}2" cryptoroot
# FIXME swap
#cryptsetup open "${DEST_DISK_PATH}3" cryptoswap

echo "[INFO] creating EFI FS"
mkfs.vfat -F32 -n EFI "${DEST_DISK_PATH}1"
echo "[INFO] creating root FS, mounting"
mkfs.btrfs -L root-btrfs /dev/mapper/cryptoroot
mount /dev/mapper/cryptoroot "${DEST_CHROOT_DIR}"
btrfs subvolume create "${DEST_CHROOT_DIR}/@"
btrfs subvolume create "${DEST_CHROOT_DIR}/@home"
btrfs subvolume create "${DEST_CHROOT_DIR}/@var_log"
btrfs subvolume create "${DEST_CHROOT_DIR}/@snapshots"
# get btrfs subvol IDs
_BTRFS_ID_ROOT=$(btrfs subvol list ${DEST_CHROOT_DIR} | grep -E "path @$" | awk '{ print $2 }')
_BTRFS_ID_HOME=$(btrfs subvol list ${DEST_CHROOT_DIR} | grep -E "path @home$" | awk '{ print $2 }')
_BTRFS_ID_VARLOG=$(btrfs subvol list ${DEST_CHROOT_DIR} | grep -E "path @var_log$" | awk '{print $2 }')
_BTRFS_ID_SNAPSHOTS=$(btrfs subvol list ${DEST_CHROOT_DIR} | grep -E "path @snapshots$" | awk '{ print $2 }')
umount /dev/mapper/cryptoroot
mount /dev/mapper/cryptoroot -o "rw,noatime,compress=lzo,ssd,discard,space_cache,commit=120,subvolid=${_BTRFS_ID_ROOT},subvol=/@,subvol=@" "${DEST_CHROOT_DIR}"
mkdir -p "${DEST_CHROOT_DIR}/home"
mount /dev/mapper/cryptoroot -o "rw,noatime,compress=lzo,ssd,discard,space_cache,commit=120,subvolid=${_BTRFS_ID_HOME},subvol=/@home,subvol=@home" "${DEST_CHROOT_DIR}/home"
mkdir -p "${DEST_CHROOT_DIR}/var/log"
mount /dev/mapper/cryptoroot -o "rw,noatime,compress=lzo,ssd,discard,space_cache,commit=120,subvolid=${_BTRFS_ID_VARLOG},subvol=/@var_log,subvol=@var_log" "${DEST_CHROOT_DIR}/var/log"
mkdir -p "${DEST_CHROOT_DIR}/.snapshots"
mount /dev/mapper/cryptoroot -o "rw,noatime,compress=lzo,ssd,discard,space_cache,commit=120,subvolid=${_BTRFS_ID_SNAPSHOTS},subvol=/@snapshots,subvol=@snapshots" "${DEST_CHROOT_DIR}/.snapshots"
echo "[INFO] mounting EFI"
mkdir -p "${DEST_CHROOT_DIR}/boot"
mount "${DEST_DISK_PATH}1" "${DEST_CHROOT_DIR}/boot"

echo "[DEBUG] showing dir content, mount, df"
ls -la "${DEST_CHROOT_DIR}"
mount
df -h

echo "[INFO] installing base system"
pacstrap "${DEST_CHROOT_DIR}" linux linux-firmware base base-devel \
    efibootmgr intel-ucode amd-ucode \
    btrfs-progs \
    dhcpcd netctl \
    vim ansible zsh git sudo wpa_supplicant \
    man-db man-pages \
    dialog

echo "[INFO] generating fstab"
genfstab -pU "${DEST_CHROOT_DIR}" | tee -a "${DEST_CHROOT_DIR}/etc/fstab"

echo "[INFO] going into chroot"
cp ./step2.sh "${DEST_CHROOT_DIR}/root/step2.sh"
# shellcheck disable=SC2154
systemd-nspawn --private-users=no -E "http_proxy=${http_proxy:-}" -D "${DEST_CHROOT_DIR}" /bin/bash -x /root/step2.sh
echo "[INFO] installing bootloader, configs"
arch-chroot "${DEST_CHROOT_DIR}" bootctl --path=/boot install
echo "default  arch.conf
timeout  4
console-mode max
editor   no" >"${DEST_CHROOT_DIR}/boot/loader/loader.conf"
echo "title Arch Linux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /amd-ucode.img
initrd /initramfs-linux.img
options rd.luks.name=$(blkid -s UUID -o value "${DEST_DISK_PATH}"2)=cryptoroot rd.luks.options=discard  root=UUID=$(blkid -s UUID -o value /dev/mapper/cryptoroot) rootflags=subvol=@ rw
" >"${DEST_CHROOT_DIR}/boot/loader/entries/arch.conf"

echo "FINISHED!"
echo "If you would like to chroot into the system please run this:"
echo "systemd-nspawn --private-users=no -E \"http_proxy=${http_proxy:-}\" -D \"${DEST_CHROOT_DIR}\" /bin/bash"
echo "or"
echo "arch-chroot \"${DEST_CHROOT_DIR}\""
