# arch installer designdoc


## non-goals (currently)
* secure boot

## goals
* public release at some point

### development
* easy testing / usage
    * should be able to start a VM which does start the installer with minimal manual intervention
    * should be able to start a laptop via netboot/usb archlinux default image, curl $something
* we start simple with a bash script, may switch to bash-then-(ansible|...) if things get complicated
* CI is locally via https://pre-commit.com/
    * linting
        * shellcheck
    * formatting
        * shfmt

### basic features
* boot via UEFI, it is 2020
* partitioning
    * efi, crypto|zfs-with-native-crypto
        * ext4 | btrfs+subvols
        * swap crypted
            * --> no suspend to disc?
* encryption, modern crypto
    * LUKS2?
    * PBKDF2-sha256 | argon2i | aes-xts-512b
    * backup master-key-file?
* systemd-boot
* 
* systemd as far as possible
    * systemd-boot
    * network manager
    * timesync
    * ...
* backup to usb or network
    * borg, restic, rsync, zfs
* user-stuff
    * ssh-keygen (rsa4096+ed25519)
        * revisit https://infosec.mozilla.org/guidelines/openssh.html#key-generation
    * ssh-client/-agent config
    * gpg-keygen (rsa4096, 3y)
        * revisit https://infosec.mozilla.org/guidelines/key_management.html#pgpgnupg
    * gpg-client/-agent config
    * WM, DM
        * wayland/x11?
            * TBD
        * login-screen
        * lock-screen
        * i3/gnome/kde/...? perhaps via pkg groups as already existing in arch
    * sound
    * multimedia (vlc, codecs?)
* additional tools
    * gopass
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


#### braindump/ideas
* netboot ala netboot.xyz ?
* build image, e.g. via kiwi to include
    * installer-script
    * features like ZFS

### usage
