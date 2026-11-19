#!/usr/bin/env bash
# CP13: run the transport-only inner relay INSIDE the VM
# (browser(outer) :8443 -> shared unix socket -> this relay -> real :443 TLS)
exec python3 /root/hanaso-ops-terminal/tests/cp13-fwd.py inner /mnt/shared/cp13.sock 127.0.0.1 443
