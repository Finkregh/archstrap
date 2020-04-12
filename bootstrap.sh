#!/usr/bin/env bash
set -euo pipefail

echo "Lets choose a destination disk. It will be used whole and __existing partitions will be removed___!"

read -p "Do you want to continue? (y/n)" -n 1 -r
echo # (optional) move to a new line
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    [[ "$0" = "$BASH_SOURCE" ]] && exit 1 || return 1 # handle exits from shell or function but don't exit interactive shell
fi

#read -r _disk_name _ _disk_size _disk_path < <(lsblk -o NAME,TYPE,SIZE,PATH --noheadings | grep disk)

declare -a _DISK_CHOOSE_OPTIONS
readarray _DISKS < <(lsblk -o TYPE,SIZE,PATH --noheadings | grep disk)
for _disk in "${_DISKS[@]}"; do
    read -r _ _disk_size _disk_path < <(echo "${_disk}")
    _DISK_CHOOSE_OPTIONS+=("${_disk_path}" "Size: ${_disk_size}")
done
_DESTINATION_DISK=$(dialog --clear \
    --backtitle "Choose a disk to write to" \
    --title "Choose a disk to write to" \
    --menu "Available disks" 15 40 4 \
    "${_DISK_CHOOSE_OPTIONS[@]}" \
    2>&1 >/dev/tty)

declare -r DEST_DISK_PATH="${_DESTINATION_DISK}"
declare -r DEST_DISK_NAME="$(basename ${_DESTINATION_DISK})"
#declare -r PACKAGELIST="sudo,popularity-contest"
declare -r DEST_CHROOT_DIR="/mnt/tmp"

mkdir -p "${DEST_CHROOT_DIR}"

# partition disk
# clear partition table
sgdisk --zap-all "${DEST_DISK_PATH}"
# UEFI - could also be 512M, discuss
sgdisk -n2:1M:+1G -t2:EF00 -c 2:efi "${DEST_DISK_PATH}"
# root (minus 4 GiB for swap
sgdisk -n3:0:-4G -t3:8309 -c 3:crypt-root "${DEST_DISK_PATH}"
# swap
sgdisk -n4:0:0 -t4:8309 -c 4:crypt-swap "${DEST_DISK_PATH}"
# update partition table
partprobe
sleep 5

# setup disk encryption
echo "Setting up disk encryption, please enter a proper passphrase next."
# root, use longer time to do PBKDF2 passphrase processing
cryptsetup --iter-time 5000 luksFormat "${DEST_DISK_PATH}3"
# swap
# FIXME setup key file in created FS later... of use $something more simple
#cryptsetup open --type plain <device> <dmname>

# open crypto container
cryptsetup open "${DEST_DISK_PATH}3" cryptoroot
# FIXME swap
#cryptsetup open "${DEST_DISK_PATH}4" cryptoswap

# create root FS
mkfs.btrfs -L root-btrfs /dev/mapper/cryptoroot
mount /dev/mapper/cryptoroot "${DEST_CHROOT_DIR}"
btrfs subvolume create "${DEST_CHROOT_DIR}/@"
btrfs subvolume create "${DEST_CHROOT_DIR}/@home"
btrfs subvolume create "${DEST_CHROOT_DIR}/@var_log"
btrfs subvolume create "${DEST_CHROOT_DIR}/@snapshots"
# get btrfs subvol IDs
_BTRFS_ID_ROOT=$(btrfs subvol list ${DEST_CHROOT_DIR} | grep -E "path @$" | awk 'print $2')
_BTRFS_ID_HOME=$(btrfs subvol list ${DEST_CHROOT_DIR} | grep -E "path @/home$" | awk 'print $2')
_BTRFS_ID_VARLOG=$(btrfs subvol list ${DEST_CHROOT_DIR} | grep -E "path @var_log" | awk 'print $2')
_BTRFS_ID_SNAPSHOTS=$(btrfs subvol list ${DEST_CHROOT_DIR} | grep -E "path @snapshots" | awk 'print $2')
umount /dev/mapper/cryptoroot
mount /dev/mapper/cryptoroot -o rw,noatime,compress=lzo,ssd,discard,space_cache,commit=120,subvolid=${_BTRFS_ID_ROOT},subvol=/@,subvol=@ ${DEST_CHROOT_DIR}

ls -la ${DEST_CHROOT_DIR}
