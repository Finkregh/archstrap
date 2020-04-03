#!/usr/bin/env bash

echo "perhaps setup networking as described in https://wiki.qemu.org/Features/HelperNetworking or change 'virbr0' below to an existing bridge"

# you can also boot via network:
#wget -nc https://boot.netboot.xyz/ipxe/netboot.xyz-efi.iso -O boot.iso
wget -nc http://ftp.hosteurope.de/mirror/ftp.archlinux.org/iso/2020.04.01/archlinux-2020.04.01-x86_64.iso -O boot.iso
qemu-img create -f qcow2 qemu-hdd.qcow2 20G
#qemu-system-x86_64 -machine accel=kvm -smp 2 -m 1024 -drive if=pflash,format=raw,readonly,file=/usr/share/ovmf/x64/OVMF_CODE.fd -drive format=qcow2,file=/home/ol/work/b1/archstrap/mkosi/image.qcow2 -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0,id=rng-device0
# -netdev user,id=n1 -device virtio-net-pci,netdev=n1
if [ ! -e /etc/qemu/bridge.conf ]; then
    echo "please create '/etc/qemu/bridge.conf' with 'allow virbr0'"
    exit 1
fi

echo "Starting http server to download stuff into the VM..."
echo "You can then run 'curl http://GATEWAY_IP:8080/step1.sh'"
python3 -m http.server --bind :: 8080 &

echo "Starting VM..."
qemu-system-x86_64 -machine accel=kvm -smp 2 -m 4096 \
    -net nic -net bridge,br=virbr0 \
    -boot d -cdrom boot.iso \
    -drive if=pflash,format=raw,readonly,file=/usr/share/ovmf/x64/OVMF_CODE.fd \
    -drive if=virtio,format=qcow2,file=qemu-hdd.qcow2 \
    -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0,id=rng-device0
