#!/usr/bin/env bash
set -euo pipefail

echo "This will generate 'arch_bootstrapped-0.1-x86_64.iso'"
echo "You might have to remove 'archlive' completely after an update of 'archiso'"

if [ -e archlive/out/arch_bootstrapped-0.1-x86_64.iso ]; then
    read -p "archlive/out/arch_bootstrapped-0.1-x86_64.iso already exists, remove? (y/N)" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -v archlive/work/build.make_*
        rm -rf archlive/out
    else
        echo "ok, exiting"
        exit 0
    fi
fi

if [ ! -e archlive ]; then
    echo "copy default template/scripts from archlinux package 'archiso'"
    cp -r /usr/share/archiso/configs/releng archlive
fi

echo "copying own files into ISO-root"
rsync -av iso-files/ archlive/airootfs/

pushd archlive
echo "ISO generation needs root rights"
# setting fixed version to always get same iso name
sudo ./build.sh -N arch_bootstrapped -V 0.1
