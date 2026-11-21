#!/usr/bin/env bash
# Root-only. One INPUT rule for UDP 443, comment mjolnir-relay.
# add is a no-op when that rule is already present. del removes every copy.
set -euo pipefail
comment=mjolnir-relay

present() {
    iptables -S INPUT 2>/dev/null | grep -q -- "--comment ${comment}"
}

case "${1:-}" in
    add)
        if present; then
            echo "relay-rule: add already" >&2
            exit 0
        fi
        echo "relay-rule: add" >&2
        iptables -I INPUT -p udp --dport 443 -m comment --comment "$comment" -j ACCEPT
        ;;
    del)
        while present; do
            spec="$(iptables -S INPUT | grep -- "--comment ${comment}" | head -1 | sed 's/^-A /-D /')"
            # shellcheck disable=SC2086
            iptables $spec
        done
        ;;
    *)
        echo "relay-rule: add or del" >&2
        exit 2
        ;;
esac
