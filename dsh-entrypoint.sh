#!/bin/sh
# Start the harness inside a container.
#
# The `web` profile refuses wildcard hosts, so the default binds this container's
# own address — the concrete interface a published port forwards to. Pass the
# whole command to bind something else:
#   docker run <image> web --host 10.0.0.7 --port 9000 --no-open
set -eu

if [ "$#" -eq 0 ]; then
  address="$(hostname -i 2>/dev/null | cut -d' ' -f1)"
  if [ -z "$address" ]; then
    echo "dsh: this container has no resolvable address; pass an explicit command, for example 'web --host <address>'" >&2
    exit 1
  fi
  set -- web --host "$address" --port 3080 --no-open
fi

exec node "$DSH_ENTRY" "$@"
