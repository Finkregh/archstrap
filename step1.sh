#!/usr/bin/env bash

## create UEFI partition
cgdisk /dev/vda
mkfs.vfat -F32 -n EFI /dev/vda1

#cryptsetup
cryptsetup --use-random luksFormat /dev/vda2
cryptsetup luksOpen /dev/vda2 luks
pvcreate /dev/mapper/luks
vgcreate vg0 /dev/mapper/luks
lvcreate --size 4G vg0 --name swap
lvcreate -l +100%FREE vg0 --name root
mkfs.ext4 -L root /dev/mapper/vg0-root
mkswap /dev/mapper/vg0-swap
mount /dev/mapper/vg0-root /mnt
swapon /dev/mapper/vg0-swap

mkdir /mnt/boot
mount /dev/vda1 /mnt/boot
pacstrap /mnt linux linux-firmware base base-devel efibootmgr dialog intel-ucode lvm2 dhcpcd netctl vim ansible zsh git sudo
while true; do
    read -p 'Do you want to install software for notebooks (e.g. wifi): y/n ' yn
    case $yn in
    [Yy]*) pacstrap /mnt wpa_supplicant ;;
    [Nn]*) break ;;
    *) echo "Please choose yes or no" ;;
    esac
done

while true; do
    read -p 'Do you want to install i3 Destop environment?: y/n ' yn
    case $yn in
    [Yy]*) pacstrap /mnt i3-vm xorg xorg-xinit i3blocks i3lock i3status ;;
    [Nn]*) break ;;
    esac
done

genfstab -pU /mnt | tee -a /mnt/etc/fstab
cp ./step2.sh /mnt/root/step2.sh
chmod +x /mnt/root/step2.sh
arch-chroot /mnt /root/step2.sh
