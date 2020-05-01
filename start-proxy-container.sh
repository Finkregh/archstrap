#!/usr/bin/env bash
set -euo pipefail
set -x

docker run --name squid -d -p 3128:3128 --volume "${PWD}/squid/config/squid.conf:/etc/squid/squid.conf:ro" --volume "${PWD}/squid/cache:/var/spool/squid" datadog/squid

printf "You can now use\n\n\texport http_proxy='http://127.0.0.1:3128/'\nto cache arch pkgs"
