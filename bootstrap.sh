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
  --defaultno \
  --yesno \
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
        --insecure \
        --passwordbox "Setting up disk encryption for ${DEST_DISK_PATH}.\n\nPlease enter a proper passphrase.\nThis password will be the initial root password, too." \
        0 0 \
        2>&1 1>&3)
    exec 3>&-
    exec 3>&1
    _CRYPT_ROOT_PASSWORD_COMPARE=$(dialog \
        --insecure \
        --passwordbox "Please repeat your passphrase." \
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

{
umount "$DEST_CHROOT_DIR"
# proper mount all the subvolumes
for subvol in '@' '@home' '@var_log' '@snapshots' '@swap'; do
    btrfs_mount_point="${subvol#@}"
    btrfs_mount_point="${btrfs_mount_point/_///}"
    # build up the mount options to not have a line length of 9001
    btrfs_mount_options='noatime,compress=lzo,ssd,discard,commit=120'
    btrfs_mount_options+=",subvol=${subvol}"
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
declare -r swapfile="${DEST_CHROOT_DIR}/swap/file"
{
# setting up the SWAP "file" in the @swap subvolume
# the swap will be as big as the RAM
# https://wiki.archlinux.org/index.php/Swap#Swap_file_creation
truncate -s 0 "$swapfile"
chattr +C "$swapfile"
chmod 600 "$swapfile"
btrfs property set "$swapfile" compression none
declare -i system_mem
# /proc/meminfo contains the value in kB
while read -r mem_option mem_value _; do
    if [[ "$mem_option" == 'MemTotal:' ]]; then
        system_mem="$mem_value"
        break
    fi
done < /proc/meminfo
# fallocate uses Bytes for the size
fallocate -l "$((system_mem * 1024))" "$swapfile"
mkswap -L swap-file "$swapfile"
swapon "$swapfile"
} | dialog --progressbox "Formatting and setting up $swapfile" 0 0
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
pacstrap -c "${DEST_CHROOT_DIR}" "${packages_to_install[@]}"
} | dialog --progressbox "Installing packages into $DEST_CHROOT_DIR" 0 0


# 6.: create fstab
{
for subvol in '@home' '@var_log' '@snapshots' '@swap'; do
    btrfs_mount_point="${subvol#@}"
    btrfs_mount_point="${btrfs_mount_point/_///}"
    btrfs_mount_options='noatime,compress=lzo,ssd,discard,commit=120,noauto,x-systemd.automount,x-systemd.idle-timeout=10'
    printf '/dev/mapper/cryptoroot %s btrfs %s,subvol=%s 0 0\n' "$btrfs_mount_point" "$btrfs_mount_options" "$subvol"
    printf '/swap/file none swap defaults 0 0\n'
done
} | tee "${DEST_CHROOT_DIR}/etc/fstab" | dialog --progressbox "Creating /etc/fstab" 0 0


# 7.: misc config
{
# 7.1.: set keymap
{
echo 'KEYMAP=de-latin1-nodeadkeys'
echo 'FONT=Lat2-Terminus16'
} > "$DEST_CHROOT_DIR/etc/vconsole.conf"
# 7.2.: set locales
{
{
echo 'LANG=en_US.UTF-8'
echo 'LC_COLLATE=C'
} > "$DEST_CHROOT_DIR/etc/locale.conf"
{
echo 'en_US.UTF-8 UTF-8'
echo 'de_DE.UTF-8 UTF-8'
} > "$DEST_CHROOT_DIR/etc/locale.gen"
{
systemd-nspawn -D "$DEST_CHROOT_DIR" -- /usr/bin/locale-gen
} | dialog --progressbox "Generating locales" 0 0
}
# 7.3.: time stuff
{
unlink "${DEST_CHROOT_DIR}/etc/localtime"
ln -s ../usr/share/zoneinfo/Europe/Berlin "${DEST_CHROOT_DIR}/etc/localtime"
timedatectl set-local-rtc no
systemd-nspawn -D "$DEST_CHROOT_DIR" -- /usr/bin/systemctl enable systemd-timesyncd.service systemd-time-sync-wait.service
} | dialog --progressbox "Setting time stuff" 0 0
# 7.4.: hostname
{
echo "$_NEW_HOSTNAME"
} > "$DEST_CHROOT_DIR/etc/hostname"
# 7.5.: enable network
{
mkdir -p "$DEST_CHROOT_DIR/etc/systemd/network/"
mkdir -p "$DEST_CHROOT_DIR/etc/iwd"
{
echo '[Match]'
echo 'Type=ether'
echo ''
echo '[Network]'
echo 'DHCP=yes'
} > "$DEST_CHROOT_DIR/etc/systemd/network/99-all-ethernet-dhcp.network"
{
echo '[Match]'
echo 'Type=wlan'
echo ''
echo '[Link]'
echo 'Unmanaged=yes'
} > "$DEST_CHROOT_DIR/etc/systemd/network/01-ignore-wireless-interfaces.network"
{
echo '[General]'
echo 'EnableNetworkConfiguration=true'
echo 'DisableANQP=false'
} > "$DEST_CHROOT_DIR/etc/iwd/main.conf"
systemd-nspawn -D "$DEST_CHROOT_DIR" -- /usr/bin/systemctl enable iwd.service systemd-networkd.service
}
# 7.6.: set root password
{
echo "root:$_CRYPT_ROOT_PASSWORD"
} | chpasswd -R "$DEST_CHROOT_DIR"
}


# 8.: installing and configuring the bootloader
{
# 8.1.: install systemd-boot
{
systemd-nspawn --bind /dev/disk/by-label/EFI -D "$DEST_CHROOT_DIR" -- /usr/bin/bootctl --no-pager install
} | dialog --progressbox "Installing systemd-boot into LABEL=EFI" 0 0
# 8.2.: writing boot loader config
{
echo 'default arch'
echo 'timeout 4'
echo 'editor  no'
} > "${DEST_CHROOT_DIR}/boot/loader/loader.conf"
# 8.3.: writing boot loader entries
{
echo 'title Arch Linux'
echo 'linux /vmlinuz-linux'
echo 'initrd /amd-ucode.img'
echo 'initrd /intel-ucode.img'
echo 'initrd /initramfs-linux.img'
echo 'options luks.name="PARTLABEL=crypto-root" luks.options=discard,luks root=LABEL=root-btrfs rootflags=subvol=@,rw,discard'
} > "${DEST_CHROOT_DIR}/boot/loader/entries/arch.conf"
}


# 9.: configuring the initramfs
{
# 9.1.: writing config
{
echo 'MODULES=()'
echo 'BINARIES=(/usr/bin/fsck.btrfs /usr/bin/fsck.fat)'
echo 'FILES=()'
echo 'HOOKS=(base systemd autodetect sd-encrypt sd-shutdown sd-vconsole modconf block filesystems keyboard fsck)'
} > /etc/mkinitcpio.conf
# 9.2.: creating intramfs
{
systemd-nspawn -D "$DEST_CHROOT_DIR" -- /usr/bin/mkinitcpio -P
} | dialog --progressbox "Creating the initramfs" 0 0
}

if dialog --yesno "Your system is ready and can be rebooted. Do you want to reboot?\nIf not, you will be dropped into a root shell." 0 0; then
    systemctl reboot
fi
