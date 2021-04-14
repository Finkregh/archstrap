#!/usr/bin/env bash
# vim: set tabstop=4 softtabstop=4 expandtab shiftwidth=4 smarttab:
set -euo pipefail
set -x

_termlines=$(tput lines)
_termwidth=$(tput cols)
declare -ri _termlines=$((_termlines - 10))
declare -ri _termwidth=$((_termwidth - 10))

# mount host os' pacman cache
# shellcheck disable=SC2010
if ls -la /sys/class/block | grep -q virtio; then
  mount -t 9p -o trans=virtio,version=9p2000.L host0 /var/cache/pacman/pkg || true
fi

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
      8 ${_termwidth}
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
      --menu "Available disks" 10 ${_termwidth} 0 \
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
        11 ${_termwidth} \
        2>&1 1>&3)
      exec 3>&-
      exec 3>&1
      _CRYPT_ROOT_PASSWORD_COMPARE=$(dialog \
        --insecure \
        --passwordbox "Please repeat your passphrase." \
        11 ${_termwidth} \
        2>&1 1>&3)
      exec 3>&-
      if [[ "$_CRYPT_ROOT_PASSWORD" == "$_CRYPT_ROOT_PASSWORD_COMPARE" ]]; then
        _passwords_are_the_same='true'
      else
        dialog --msgbox "The entered passphrases don't match. Please try again." 11 ${_termwidth}
      fi
    done
  }
  # 1.4.: hostname?
  {
    exec 3>&1
    _NEW_HOSTNAME=$(dialog \
      --inputbox "What should the hostname be?" \
      11 ${_termwidth} \
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
  } | dialog --progressbox "Formatting disk $DEST_DISK_PATH" ${_termlines} ${_termwidth}
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
    "$DEST_ROOT_PART" |
    dialog --progressbox "Crypting the root partition ${DEST_ROOT_PART}" ${_termlines} ${_termwidth}

  # open crypto container
  cryptsetup --key-file <(printf '%s' "$_CRYPT_ROOT_PASSWORD") open "$DEST_ROOT_PART" cryptoroot
} | dialog --progressbox "Setting up decryption at $DEST_ROOT_PART" ${_termlines} ${_termwidth}

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
    } | dialog --progressbox "Creating btrfs subvolumes" ${_termlines} ${_termwidth}

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
        mount /dev/mapper/cryptoroot -o "${btrfs_mount_options}" "${DEST_CHROOT_DIR}/${btrfs_mount_point}" |
          dialog --progressbox "Mounting ${DEST_CHROOT_DIR}/${btrfs_mount_point}" ${_termlines} ${_termwidth}
      done
    }
  }
  # 4.2.: EFI stuff
  {
    mkfs.vfat -F32 -n EFI "$DEST_EFI_PART"
    mkdir -p "${DEST_CHROOT_DIR}/boot"
    mount "$DEST_EFI_PART" "${DEST_CHROOT_DIR}/boot"
  } | dialog --progressbox "Formatting and mounting the EFI partition ${DEST_EFI_PART}" ${_termlines} ${_termwidth}
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
    done </proc/meminfo
    # fallocate uses Bytes for the size
    fallocate -l "$((system_mem * 1024))" "$swapfile"
    mkswap -L swap-file "$swapfile"
    swapon "$swapfile"
  } | dialog --progressbox "Formatting and setting up $swapfile" ${_termlines} ${_termwidth}
}

# 5.: install packages into new system
{
  declare -a packages_to_install=()
  packages_to_install+=('base' 'base-devel' 'linux')
  packages_to_install+=('linux-firmware' 'intel-ucode' 'amd-ucode' 'fwupd')
  packages_to_install+=('btrfs-progs' 'dosfstools')
  packages_to_install+=('iwd') # better replacement for wpa_supplicant
  packages_to_install+=('sudo' 'polkit')
  packages_to_install+=('vim' 'zsh' 'git' 'man-db' 'man-pages')
  packages_to_install+=('pacman-contrib')
  packages_to_install+=('cockpit' 'cockpit-podman' 'cockpit-machines') # cockpit is a fancy web base for system administration
  pacstrap "${DEST_CHROOT_DIR}" "${packages_to_install[@]}"
} | dialog --progressbox "Installing packages into $DEST_CHROOT_DIR" ${_termlines} ${_termwidth}

# 6.: create fstab
{
  for subvol in '@home' '@var_log' '@snapshots' '@swap'; do
    btrfs_mount_point="${subvol#@}"
    btrfs_mount_point="${btrfs_mount_point/_//}"
    btrfs_mount_options='noatime,compress=lzo,ssd,discard,commit=120,noauto,x-systemd.automount,x-systemd.idle-timeout=10'
    printf '/dev/mapper/cryptoroot /%s btrfs %s,subvol=%s 0 0\n' "$btrfs_mount_point" "$btrfs_mount_options" "$subvol"
  done
  printf '/swap/file none swap defaults 0 0\n'
} | tee "${DEST_CHROOT_DIR}/etc/fstab" | dialog --progressbox "Creating /etc/fstab" ${_termlines} ${_termwidth}

# 7.: misc config
{
  # 7.1.: set keymap
  {
    echo 'KEYMAP=de-latin1-nodeadkeys'
    echo 'FONT=Lat2-Terminus16'
  } >"$DEST_CHROOT_DIR/etc/vconsole.conf"
  # 7.2.: set locales
  {
    {
      echo 'LANG=en_US.UTF-8'
      echo 'LC_COLLATE=C'
    } >"$DEST_CHROOT_DIR/etc/locale.conf"
    {
      echo 'en_US.UTF-8 UTF-8'
      echo 'de_DE.UTF-8 UTF-8'
    } >"$DEST_CHROOT_DIR/etc/locale.gen"
    {
      systemd-nspawn -D "$DEST_CHROOT_DIR" -- /usr/bin/locale-gen
    } | dialog --progressbox "Generating locales" ${_termlines} ${_termwidth}
  }
  # 7.3.: time stuff
  {
    unlink "${DEST_CHROOT_DIR}/etc/localtime"
    ln -s ../usr/share/zoneinfo/Europe/Berlin "${DEST_CHROOT_DIR}/etc/localtime"
    timedatectl set-local-rtc no
    systemd-nspawn -D "$DEST_CHROOT_DIR" -- /usr/bin/systemctl enable systemd-timesyncd.service systemd-time-wait-sync.service
  } | dialog --progressbox "Setting time stuff" ${_termlines} ${_termwidth}
  # 7.4.: hostname
  {
    echo "$_NEW_HOSTNAME"
  } >"$DEST_CHROOT_DIR/etc/hostname"
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
      echo 'LLMNR=yes'
      echo 'MulticastDNS=yes'
    } >"$DEST_CHROOT_DIR/etc/systemd/network/99-all-ethernet-dhcp.network"
    {
      echo '[Match]'
      echo 'Type=wlan'
      echo ''
      echo '[Link]'
      echo 'Unmanaged=yes'
    } >"$DEST_CHROOT_DIR/etc/systemd/network/01-ignore-wireless-interfaces.network"
    {
      echo '[General]'
      echo 'EnableNetworkConfiguration=true'
      echo 'DisableANQP=false'
    } >"$DEST_CHROOT_DIR/etc/iwd/main.conf"
    systemd-nspawn -D "$DEST_CHROOT_DIR" -- /usr/bin/systemctl enable iwd.service systemd-networkd.service systemd-resolved.service
  }
  # 7.6.: set root password
  {
    echo "root:$_CRYPT_ROOT_PASSWORD"
  } | chpasswd -R "$DEST_CHROOT_DIR"
  # 7.7.: enable cockpit
  {
    systemd-nspawn -D "$DEST_CHROOT_DIR" -- /usr/bin/systemctl enable cockpit.socket
  }
}

# 8.: installing and configuring the bootloader
{
  # 8.1.: install systemd-boot
  {
    systemd-nspawn --bind /dev/disk/by-label/EFI -D "$DEST_CHROOT_DIR" -- /usr/bin/bootctl --no-pager install
  } | dialog --progressbox "Installing systemd-boot into LABEL=EFI" ${_termlines} ${_termwidth}
  # 8.2.: writing boot loader config
  {
    echo 'default arch'
    echo 'timeout 4'
    echo 'editor  no'
  } >"${DEST_CHROOT_DIR}/boot/loader/loader.conf"
  # 8.3.: writing boot loader entries
  {
    {
      declare LUKS_UUID=''
      while IFS='=' read -r property value; do
        if [[ "$property" == 'ID_FS_UUID' ]]; then
          LUKS_UUID="$value"
          break
        fi
      done < <(udevadm info --query=property "$DEST_ROOT_PART")
    }
    {
      echo 'title Arch Linux'
      echo 'linux /vmlinuz-linux'
      echo 'initrd /amd-ucode.img'
      echo 'initrd /intel-ucode.img'
      echo 'initrd /initramfs-linux.img'
      echo "options luks.name=${LUKS_UUID}=cryptoroot luks.options=discard,luks root=LABEL=root-btrfs rootflags=subvol=@,rw,discard"
    } >"${DEST_CHROOT_DIR}/boot/loader/entries/arch.conf"
  }
}

# 9.: configuring the initramfs
{
  # 9.1.: writing config
  {
    echo 'MODULES=(vfat btrfs)'
    echo 'BINARIES=(/usr/bin/fsck.btrfs /usr/bin/fsck.fat /usr/bin/btrfs /usr/bin/bash /usr/bin/cryptsetup /usr/bin/vim)'
    echo 'FILES=()'
    echo 'HOOKS=(systemd autodetect sd-encrypt sd-shutdown sd-vconsole modconf block filesystems keyboard fsck)'
  } >"${DEST_CHROOT_DIR}/etc/mkinitcpio.conf"
  # 9.2.: creating intramfs
  {
    systemd-nspawn -D "$DEST_CHROOT_DIR" -- /usr/bin/mkinitcpio -P
  } | dialog --progressbox "Creating the initramfs" ${_termlines} ${_termwidth}
}

# 10.: various config
{
  # 9.1.: pacman mirrorlist
  {
    # only old, "known" mirrors chosen
    echo '
    ## Generated on 2020-05-02
#Server = http://mirror.23media.com/archlinux/$repo/os/$arch
#Server = https://mirror.23media.com/archlinux/$repo/os/$arch
#Server = https://appuals.com/archlinux/$repo/os/$arch
#Server = http://artfiles.org/archlinux.org/$repo/os/$arch
#Server = https://mirror.bethselamin.de/$repo/os/$arch
#Server = http://mirror.chaoticum.net/arch/$repo/os/$arch
#Server = https://mirror.chaoticum.net/arch/$repo/os/$arch
#Server = http://mirror.checkdomain.de/archlinux/$repo/os/$arch
#Server = https://mirror.checkdomain.de/archlinux/$repo/os/$arch
#Server = http://mirror.f4st.host/archlinux/$repo/os/$arch
#Server = https://mirror.f4st.host/archlinux/$repo/os/$arch
Server = http://ftp.fau.de/archlinux/$repo/os/$arch
Server = https://ftp.fau.de/archlinux/$repo/os/$arch
Server = https://dist-mirror.fem.tu-ilmenau.de/archlinux/$repo/os/$arch
Server = http://ftp.gwdg.de/pub/linux/archlinux/$repo/os/$arch
#Server = http://archlinux.honkgong.info/$repo/os/$arch
Server = http://ftp.hosteurope.de/mirror/ftp.archlinux.org/$repo/os/$arch
Server = http://ftp-stud.hs-esslingen.de/pub/Mirrors/archlinux/$repo/os/$arch
#Server = http://archlinux.mirror.iphh.net/$repo/os/$arch
#Server = http://arch.jensgutermuth.de/$repo/os/$arch
#Server = https://arch.jensgutermuth.de/$repo/os/$arch
#Server = http://mirror.fra10.de.leaseweb.net/archlinux/$repo/os/$arch
#Server = https://mirror.fra10.de.leaseweb.net/archlinux/$repo/os/$arch
#Server = http://mirror.metalgamer.eu/archlinux/$repo/os/$arch
#Server = https://mirror.metalgamer.eu/archlinux/$repo/os/$arch
#Server = http://mirror.mikrogravitation.org/archlinux/$repo/os/$arch
#Server = https://mirror.mikrogravitation.org/archlinux/$repo/os/$arch
#Server = https://mirror.pkgbuild.com/$repo/os/$arch
Server = http://mirrors.n-ix.net/archlinux/$repo/os/$arch
Server = https://mirrors.n-ix.net/archlinux/$repo/os/$arch
Server = http://mirror.netcologne.de/archlinux/$repo/os/$arch
Server = https://mirror.netcologne.de/archlinux/$repo/os/$arch
#Server = http://mirrors.niyawe.de/archlinux/$repo/os/$arch
#Server = https://mirrors.niyawe.de/archlinux/$repo/os/$arch
#Server = http://mirror.orbit-os.com/archlinux/$repo/os/$arch
#Server = https://mirror.orbit-os.com/archlinux/$repo/os/$arch
#Server = http://packages.oth-regensburg.de/archlinux/$repo/os/$arch
#Server = https://packages.oth-regensburg.de/archlinux/$repo/os/$arch
Server = http://ftp.halifax.rwth-aachen.de/archlinux/$repo/os/$arch
Server = https://ftp.halifax.rwth-aachen.de/archlinux/$repo/os/$arch
#Server = http://linux.rz.rub.de/archlinux/$repo/os/$arch
Server = http://mirror.selfnet.de/archlinux/$repo/os/$arch
Server = https://mirror.selfnet.de/archlinux/$repo/os/$arch
#Server = http://archlinux.thaller.ws/$repo/os/$arch
#Server = https://archlinux.thaller.ws/$repo/os/$arch
Server = http://ftp.tu-chemnitz.de/pub/linux/archlinux/$repo/os/$arch
#Server = http://mirror.ubrco.de/archlinux/$repo/os/$arch
#Server = https://mirror.ubrco.de/archlinux/$repo/os/$arch
Server = http://ftp.uni-kl.de/pub/linux/archlinux/$repo/os/$arch
#Server = http://mirror.united-gameserver.de/archlinux/$repo/os/$arch
#Server = http://ftp.wrz.de/pub/archlinux/$repo/os/$arch
#Server = https://ftp.wrz.de/pub/archlinux/$repo/os/$arch
#Server = http://mirror.wtnet.de/arch/$repo/os/$arch
#Server = https://mirror.wtnet.de/arch/$repo/os/$arch
    ' >"$DEST_CHROOT_DIR/etc/pacman.d/mirrorlist-de-curated"
    systemd-nspawn -D "$DEST_CHROOT_DIR" -- rankmirrors -n 10 /etc/pacman.d/mirrorlist-de-curated >"$DEST_CHROOT_DIR/etc/pacman.d/mirrorlist"
  } | dialog --progressbox "Creating ranked pacman mirrorlist" ${_termlines} ${_termwidth}

  # 10.2.: figure out and install gfx drivers
  {
    _gfxidentifier="$(lspci | grep -e VGA -e 3D)"
    declare -r _gfxidentifier
    case "$_gfxidentifier" in
    #*\ Intel\ *) pacstrap $DEST_CHROOT_DIR xf86-video-intel ;; # disabled following https://github.com/Finkregh/archstrap/pull/10#discussion_r427403432
    *\ NVIDIA\ *) pacstrap $DEST_CHROOT_DIR xf86-video-nouveau ;;
    *\ AMD\ *) echo "please install 'xf86-video-amdgpu' or 'xf86-video-ati', see <https://wiki.archlinux.org/index.php/Xorg#Driver_installation>" ;;
    *\ ATI\ *) echo "please install 'xf86-video-amdgpu' or 'xf86-video-ati', see <https://wiki.archlinux.org/index.php/Xorg#Driver_installation>" ;;
    esac
  } | dialog --progressbox "Installing GFX drivers" ${_termlines} ${_termwidth}
  # 10.3.: install DM
  {
    pacstrap $DEST_CHROOT_DIR lightdm lightdm-gtk-greeter
    systemd-nspawn -D "$DEST_CHROOT_DIR" -- /usr/bin/systemctl enable lightdm.service
    # FIXME config, theme
  } | dialog --progressbox "Installing display manager lightdm" ${_termlines} ${_termwidth}
}

if dialog --yesno "Your system is ready and can be rebooted. Do you want to reboot?\nIf not, you will be dropped into a root shell." ${_termlines} ${_termwidth}; then
  systemctl reboot
fi
