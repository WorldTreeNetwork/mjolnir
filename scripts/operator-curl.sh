#!/usr/bin/env bash
# curl against the Mjolnir API as the operator.
#
# When /run/mjolnir/operator.sock exists, that socket is the principal
# (mode 0600, root). TCP to 127.0.0.1:4000 is not. Until the release that
# creates the socket is running, fall back to plain curl so the previous
# loopback bypass still answers.
#
# Arguments are passed straight to curl. Use a normal http://localhost:4000
# URL; curl ignores the port when --unix-socket is set and still sends the
# path.
set -euo pipefail

sock="${MJOLNIR_OPERATOR_SOCKET:-/run/mjolnir/operator.sock}"
if [[ -S "$sock" ]]; then
  exec curl --unix-socket "$sock" "$@"
else
  exec curl "$@"
fi
