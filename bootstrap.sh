#!/usr/bin/env bash
# vim: set tabstop=4 softtabstop=4 expandtab shiftwidth=4 smarttab:
set -euo pipefail
set -x

# 1.: asking stuff
{
# 1.1.: really?
{
# shows a dialog (duh) asking for confirmation. It contains a red \Z1 bold \Zb warning. The warning is set back at \Zn.
# the size is determined automatically (0 0)
dialog --colors \
  --yesno \
  --defaultno \
  'Starting here will be dragons! Be sure to have a backup or do not care about your data!:\n\Z1\ZbExisting partitions will be removed!\Zn\n\nDo you want to continue?' \
  0 0
declare -i _dialog_return="$?"
if ((_dialog_return != 0)); then
    [[ "$0" == "${BASH_SOURCE[0]}" ]] && exit 1 || return 1 # handle exits from shell or function but don't exit interactive shell
fi
}
# 1.2.: which disk?
{
declare -a _DISK_CHOOSE_OPTIONS=()
while read -r _disk_type _disk_size _disk_path; do
    if [[ "$_disk_type" == 'disk' ]]; then
        _DISK_CHOOSE_OPTIONS+=("$_disk_path" "Size: $_disk_size")
    fi
done < <(lsblk -o TYPE,SIZE,PATH --noheadings)

# open an additional file descriptor (fd3) to allow usage of dialog inside the subshell and redirecting its output
exec 3>&1
DEST_DISK_PATH=$(dialog --backtitle "Choose a disk to write to" \
  --title "Choose a disk to write to" \
  --menu "Available disks" 0 0 0 \
  "${_DISK_CHOOSE_OPTIONS[@]}" \
  2>&1 1>&3)
# close the additional fd
exec 3>&-
}
# 1.3.: ask for encryption/root password
{
declare _passwords_are_the_same='false'
until [[ "$_passwords_are_the_same" == 'true' ]]; do
    exec 3>&1
    _CRYPT_ROOT_PASSWORD=$(dialog \
        --passwordbox "Setting up disk encryption for ${DEST_ROOT_PART}.\n\nPlease enter a proper passphrase.\nThis password will be the initial root password, too." \
        --insecure \
        0 0 \
        2>&1 1>&3)
    exec 3>&-
    exec 3>&1
    _CRYPT_ROOT_PASSWORD_COMPARE=$(dialog \
        --passwordbox "Please repeat your passphrase." \
        --insecure \
        0 0 \
        2>&1 1>&3)
    exec 3>&-
    if [[ "$_CRYPT_ROOT_PASSWORD" == "$_CRYPT_ROOT_PASSWORD_COMPARE" ]]; then
        _passwords_are_the_same='true'
    else
        dialog --msgbox "The entered passphrases don't match. Please try again." 0 0
    fi
done
}
# 1.4.: hostname?
{
exec 3>&1
_NEW_HOSTNAME=$(dialog \
    --inputbox "What should the hostname be?" \
    0 0 \
    2>&1 1>&3)
exec 3>&-
}
}


# 2.: partition disk
{
declare -r DEST_DISK_PATH
declare -r DEST_CHROOT_DIR="/mnt/tmp"
# use the fancy names from the sgdisk -c part
declare -r DEST_EFI_PART='/dev/disk/by-partlabel/efi'
declare -r DEST_ROOT_PART='/dev/disk/by-partlabel/crypt-root'

{
mkdir -p "${DEST_CHROOT_DIR}"
# clear partition table
sgdisk --zap-all "${DEST_DISK_PATH}"
# use relativ partition numbers, not hardcoded ones
# use relativ partition sizes
# ESP uses 1GiB, open for discussion
sgdisk -n0:0:+1G -t0:C12A7328-F81F-11D2-BA4B-00A0C93EC93B -c 0:efi "${DEST_DISK_PATH}"
# root is everything else
sgdisk -n0:0:0 -t0:CA7D7CCB-63ED-4C53-861C-1742536059CC -c 0:crypt-root "${DEST_DISK_PATH}"
# update partition table
partprobe
sleep 5
} | dialog --progressbox "Formatting disk $DEST_DISK_PATH" 0 0
}


# 3.: setup disk encryption
{
# read passwort from variable provided by dialog
# argon2i is preferable over pbkdf2 as it also has additional memory and CPU costs instead of just time costs
# pbkdf-memory is messured in KiB, we want to use 1GiB of RAM
# pbkdf-parallel defines how many threads are used, but never more than NR(cpus_online)
# batch-mode just runs the application, no questions asked!
cryptsetup --key-file <(printf '%s' "$_CRYPT_ROOT_PASSWORD") \
  --pbkdf=argon2id \
  --pbkdf-memory=$((1024 * 1024)) \
  --pbkdf-parallel=4 \
  luksFormat \
  --batch-mode \
  "$DEST_ROOT_PART" \
| dialog --progressbox "Crypting the root partition ${DEST_ROOT_PART}" 0 0

# open crypto container
cryptsetup --key-file <(printf '%s' "$_CRYPT_ROOT_PASSWORD") open "$DEST_ROOT_PART" cryptoroot
} | dialog --progressbox "Setting up decryption at $DEST_ROOT_PART" 0 0


# 4.: setup filesystem partitions, subvolumes and swap
{
# 4.1.: btrfs stuff
{
{
# create btrfs filesystem
mkfs.btrfs -L root-btrfs /dev/mapper/cryptoroot
mount LABEL=root-btrfs "${DEST_CHROOT_DIR}"
# create btrfs subvolumes
for subvol in '@' '@home' '@var_log' '@snapshots' '@swap'; do
    btrfs subvolume create "${DEST_CHROOT_DIR}/${subvol}"
done
} | dialog --progressbox "Creating btrfs subvolumes" 0 0
# get btrfs subvol IDs
declare -A _BTRFS_IDS=()
while read -r _ btrfs_id _ _ _ _ _ _ btrfs_name; do
    _BTRFS_IDS["$btrfs_id"]="$btrfs_name"
done < <(btrfs subvolume list "$DEST_CHROOT_DIR")

{
umount "$DEST_CHROOT_DIR"
# proper mount all the subvolumes
for btrfs_id in "${!_BTRFS_IDS[@]}"; do
    btrfs_name="${_BTRFS_IDS[$btrfs_id]}"
    btrfs_mount_point="${btrfs_name#@}"
    btrfs_mount_point="${btrfs_mount_point/_///}"
    # build up the mount options to not have a line length of 9001
    btrfs_mount_options='noatime,compress=lzo,ssd,discard,commit=120'
    btrfs_mount_options+=",subvolid=${btrfs_id}"
    btrfs_mount_options+=",subvol=/${btrfs_name}"
    btrfs_mount_options+=",subvol=${btrfs_name}"
    mkdir -p "${DEST_CHROOT_DIR}/${btrfs_mount_point}"
    mount /dev/mapper/cryptoroot -o "${btrfs_mount_options}" "${DEST_CHROOT_DIR}/${btrfs_mount_point}" \
    | dialog --progressbox "Mounting ${DEST_CHROOT_DIR}/${btrfs_mount_point}" 0 0
done
}
}
# 4.2.: EFI stuff
{
mkfs.vfat -F32 -n EFI "$DEST_EFI_PART"
mkdir -p "${DEST_CHROOT_DIR}/boot"
mount "$DEST_EFI_PART" "${DEST_CHROOT_DIR}/boot"
} | dialog --progressbox "Formatting and mounting the EFI partition ${DEST_EFI_PART}" 0 0
# 4.3.: swap stuff
{
# setting up the SWAP "file" in the @swap subvolume
# the swap will be as big as the RAM
# https://wiki.archlinux.org/index.php/Swap#Swap_file_creation
truncate -s 0 /swap/file
chattr +C /swap/file
chmod 600 /swap/file
btrfs property set /swap/file compression none
declare -i system_mem
# /proc/meminfo contains the value in kB
while read -r mem_option mem_value _; do
    if [[ "$mem_option" == 'MemTotal:' ]]; then
        system_mem="$mem_value"
        break
    fi
done < /proc/meminfo
# fallocate uses Bytes for the size
fallocate -l "$((system_mem * 1024))" /swap/file
mkswap -L swap-file /swap/file
swapon /swap/file
} | dialog --progressbox "Formatting and setting up /swap/file" 0 0
}


# 5.: install packages into new system
{
declare -a packages_to_install=()
packages_to_install+=('base' 'linux')
packages_to_install+=('linux-firmware' 'intel-ucode' 'amd-ucode' 'fwupd')
packages_to_install+=('btrfs-progs')
packages_to_install+=('iwd') # better replacement for wpa_supplicant
packages_to_install+=('sudo' 'polkit')
packages_to_install+=('vim' 'zsh' 'git' 'man-db' 'man-pages')
packages_to_install+=('cockpit' 'cockpit-podman' 'cockpit-machines') # cockpit is a fancy web base for system administration
pacstrap "${DEST_CHROOT_DIR}" "${packages_to_install[@]}"
} | dialog --clear --progressbox "Installing packages into $DEST_CHROOT_DIR" 0 0


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
