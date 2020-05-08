#!/usr/bin/env bash
# vim: set tabstop=4 softtabstop=4 expandtab shiftwidth=4 smarttab:
set -euo pipefail
set -x

# 1.: asking stuff
{
# shows a dialog (duh) asking for confirmation. It contains a red \Z1 bold \Zb warning. The warning is set back at \Zn.
# the size is determined automatically (0 0)
dialog --clear \
  --colors \
  --yesno \
  --defaultno \
  'Starting here will be dragons! Be sure to have a backup or do not care about your data!:\n\Z1\ZbExisting partitions will be removed!\Zn\n\nDo you want to continue?' \
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
DEST_DISK_PATH=$(dialog --clear \
  --backtitle "Choose a disk to write to" \
  --title "Choose a disk to write to" \
  --menu "Available disks" 0 0 0 \
  "${_DISK_CHOOSE_OPTIONS[@]}" \
  2>&1 1>&3)
# close the additional fd
exec 3>&-
}

declare -r DEST_DISK_PATH
declare -r DEST_CHROOT_DIR="/mnt/tmp"

mkdir -p "${DEST_CHROOT_DIR}"

# partition disk
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

# use the fancy names from the sgdisk -c part
declare -r DEST_EFI_PART='/dev/disk/by-partlabel/efi'
declare -r DEST_ROOT_PART='/dev/disk/by-partlabel/crypt-root'

mkfs.vfat -F32 -n EFI "$DEST_EFI_PART" \
| dialog --clear --progressbox "Formatting the EFI partition ${DEST_EFI_PART}" 0 0



# setup disk encryption
declare _passwords_are_the_same='false'
until [[ "$_passwords_are_the_same" == 'true' ]]; do
	exec 3>&1
	_CRYPT_ROOT_PASSWORD=$(dialog \
		--clear \
		--passwordbox "Setting up disk encryption for ${DEST_ROOT_PART}.\n\nPlease enter a proper passphrase." \
		--insecure \
		0 0 \
		2>&1 1>&3)
	exec 3>&-
	exec 3>&1
	_CRYPT_ROOT_PASSWORD_COMPARE=$(dialog \
		--clear \
		--passwordbox "Please repeat your passphrase." \
		--insecure \
		0 0 \
		2>&1 1>&3)
	exec 3>&-
	if [[ "$_CRYPT_ROOT_PASSWORD" == "$_CRYPT_ROOT_PASSWORD_COMPARE" ]]; then
		_passwords_are_the_same='true'
	else
		dialog --clear --msgbox "The entered passphrases don't match. Please try again." 0 0
	fi
done

# read passwort from variable provided by dialog
# argon2i is preferable over pbkdf2 as it also has additional memory and CPU costs instead of just time costs
# pbkdf-memory is mesured in KiB, we want to use 1GiB of RAM
# pbkdf-parallel defines how many threads are used, but never more than NR(cpus_online)
# batch-mode just runs the application, no questions asked!
cryptsetup --key-file <(printf '%s' "$_CRYPT_ROOT_PASSWORD") \
--pbkdf=argon2id \
--pbkdf-memory=$((1024 * 1024)) \
--pbkdf-parallel=4 \
luksFormat \
--batch-mode \
"$DEST_ROOT_PART" \
| dialog --clear --progressbox "Crypting the root partition ${DEST_ROOT_PART}" 0 0

# open crypto container
cryptsetup --key-file <(printf '%s' "$_CRYPT_ROOT_PASSWORD") open "$DEST_ROOT_PART" cryptoroot

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
mount "$DEST_EFI_PART" "${DEST_CHROOT_DIR}/boot"

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
