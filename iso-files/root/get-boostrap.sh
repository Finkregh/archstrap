#!/usr/bin/env bash
set -euo pipefail

# Minimal bootstrap script that can be added to an ISO.
# We keep this as minimal as possible that we do not have to patch the ISO often.
# (get as much from $source as possible)

get_from_github() {
    echo "Getting bootstrap script from https://github.com/Finkregh/archstrap"
    wget "https://raw.githubusercontent.com/Finkregh/archstrap/master/bootstrap.sh"
}
get_from_defgw() {
    echo "Getting bootstrap script from \$default_gateway:8080."
    echo "only using IPv4 for now... :(" # FIXME
    read -r _ _ gateway _ < <(ip route list match 0/0)
    wget "http://${gateway}:8080/bootstrap.sh"
}

case "${1-github}" in
local)
    get_from_defgw
    ;;
github)
    get_from_github
    ;;
    #*)
    #    echo "Neither 'github' nor 'local' chosen, using github"
    #    get_from_github
    #    ;;
esac

chmod +x bootstrap.sh

read -p "Run bootstrap.sh? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    ./bootstrap.sh
else
    echo "done, exiting"
fi
