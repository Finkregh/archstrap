# Archlinux install script

## usage

General setup:
* generate ISO with bootstrap script; should only be needed once
  * `./create-iso.sh`
  * otherwise use normal ISO and download script manually
* boot ISO in VM/PC
  * to start a qemu VM run `./start-vm.sh`
* enable network in running ISO (should happen automagically with ethernet)
* run `./get-bootstrap.sh` in the VM to download files
  * this will fetch files from github, or via `./get-bootstrap.sh local` from the
    IPv4 default gateway

## chat

![deltachat invite](deltachat-invite.jpg)


# arch installer designdoc

## non-goals (currently)
* secure boot
    * needed for secure UEFI

## goals
* ✓ public release at some point
* as secure as easily reachable, can be made more secure in later versions (e.g. add secure boot)
* get a basic version running as soon as possible, bloat will happen along the way

### development
* easy testing / usage
    * ✓ should be able to start a VM which does start the installer with minimal manual intervention
    * should be able to start a laptop via netboot/usb archlinux default image, curl $something
    * mkosi has everything we want https://github.com/systemd/mkosi
* we start simple with a bash script, may switch to bash-then-(ansible|...) if things get complicated
* CI is locally via https://pre-commit.com/
    * remove whitespace
    * linting
        * shellcheck
        * yaml, ansible ... whatever we use
    * formatting
        * shfmt

### basic features
* ✓boot via UEFI, it is 2020
* partitioning
    * efi, crypto|zfs-with-native-crypto
        * ext4 | ✓ btrfs+subvols
        * swap crypted
            * --> no suspend to disc?
        * ZFS might be not a good idea for a rolling release
        * > This situation sometimes locks down the normal rolling update process by unsatisfied dependencies because the new kernel version, proposed by update, is unsupported by ZFSonLinux.
            * ZFS is an late-extra-option, not the first thing we'll do
    * systemd-homed for only encrypted /home! (optional, later; first encrypt as much as possible)
* ✓ encryption, modern crypto
    * ~~shred/randomize before encryption - needed in times of non-rotating storage?~~
        * will wear down the storage
    * LUKS2?
        * depends on hardware and the available coprocessor - why?/link?
            * without suitable coproc the en-/decryption will be horrible slow
            * checkout `cryptsetup benchmark`
            * we suspect that this is running on post-2010 hardware?
    * PBKDF2-sha256 | argon2i | aes-xts-512b
    * backup master-key-file?
        * encrypted in git?
        * print?
            * https://wiki.archlinux.org/index.php/Paperkey ?
        * if we do this we need a recovery procedure
* ✓ systemd-boot
* TODO: work through https://wiki.archlinux.org/index.php/General_recommendations
* systemd as far as possible
    * systemd-boot (grub if we use zfs? (can grub boot directly from ZFS?-yes,dont know if /w encryption; otherwise separate encrypted /boot))
        * mkinitcpio -H zfs
        * systemd-boot needs an unencrypted fat32 ESP -> hole in security? -> By UEFI design, no problem with SecureBoot/TPM
    * network manager
    * timesync
    * initrd
    * ...
* backup to usb or network
    * borg, restic, rsync, zfs
        * borg
            * https://git.intern.b1-systems.de/henze/my_local_borg_backup
* user-stuff
    * ssh-keygen (rsa4096+ed25519)
        * revisit https://infosec.mozilla.org/guidelines/openssh.html#key-generation
    * ssh-client/-agent config
    * gpg-keygen (rsa4096, 3y)
        * revisit https://infosec.mozilla.org/guidelines/key_management.html#pgpgnupg
        * https://wiki.archlinux.org/index.php/Paperkey
        * export+print revocation+private?
    * gpg-client/-agent config
        * keyserver, do upload
    * WM, DM
        * wayland/x11?
            * TBD
        * login-screen
        * lock-screen
        * i3/gnome/kde/...? perhaps via pkg groups as already existing in arch, link to documentation
    * sound
        * pulseaudio
    * multimedia (vlc, codecs?)
    * office tooling
        * latex?
            * container? -> podman? systemd-nspawn?
        * LibreOffice
        * owncloud client
        * instant messenger (XMPP)
        * PDF viewer
        * printer drivers in working
* additional tools
    * gopass
        * integration into the DM/WM/Browser?
    * browser+extensions
        * chrome+firefox?
        * uBlock
        * httpseverywhere
        * pass access
        * firefox
            * container management
            *
    * tcpdump,strace,htop,glances,dstat,docker,iotop,gdb
    * arch-tools
        * yay, aurvote, config-management-after-update
    * microcode updates
    * fwupd
    * libvirt (qemu + virt-manager)
    * buku?


#### braindump/ideas
* netboot ala netboot.xyz ?
    * gute idee (max)
* ✓ (arch-installiso) build image, e.g. via kiwi to include
    * ✓ installer-script
    * features like ZFS
* mkosi


