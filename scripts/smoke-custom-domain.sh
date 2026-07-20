#!/usr/bin/env bash
# Smoke test + rollback for custom-domain serving (Deploy.Registry -> gateway routes).
#
# Prerequisites:
#   - ssh access to the mjolnir host (MJOLNIR_HOST, or pass as $2)
#   - jq, curl, openssl installed locally
#
# What it does:
#   verify   Discovers every app with a custom_domain from GET /api/apps, then asserts
#            for each: a [[route]] exists in the gateway drop-in, the origin serves 200
#            with a cert whose SAN covers the domain, and the public URL serves 200.
#            Also asserts the ACME cache still matches the recorded baseline.
#   snapshot Records the current route drop-in + ACME cert fingerprint as the rollback
#            baseline. Run this when things are known-good, e.g. before a deploy.
#   restore-apex <apex>
#            Re-adds an apex to :gateway_apexes and regenerates routes. This is the fix
#            when an orchestrator restart drops a custom-domain apex.
#   restore-routes
#            Restores the snapshotted route drop-in and reloads the gateway directly,
#            bypassing the orchestrator. Stopgap for when the reconciler itself is broken;
#            a later VM lifecycle event will regenerate the file, so follow with
#            restore-apex.
#
# Background — why each assertion is written the way it is:
#   * The apex list is the ONLY restart-volatile piece. Deploy.Registry is durable (one
#     JSON per app under /var/lib/mjolnir/deploy/registry/), so custom_domain survives a
#     restart; :gateway_apexes lives in config + MJOLNIR_GATEWAY_APEXES and a runtime
#     put_env does NOT survive. If a domain 404s after a restart, suspect the apex first.
#   * Origin curl MUST use -k: a Cloudflare Origin CA cert is trusted only by Cloudflare,
#     never by a public root store. A cert error at the origin is expected, not an outage.
#     So we assert on the SAN instead. Assert on the SAN, NOT the issuer string: issuer OU
#     is "CloudFlare Origin SSL Certificate Authority" while SUBJECT OU is "CloudFlare
#     Origin CA" -- grepping the wrong field yields a false "wrong cert".
#   * The ACME fingerprint is a rate-limit tripwire. [acme].domains in gateway.toml is a
#     PINNED worldtree SAN list, independent of :gateway_apexes, so adding a custom-domain
#     apex must never widen it. If the fingerprint changes after a deploy that did not
#     intend to renew, the gateway re-issued and burned Let's Encrypt quota.
#
# Run: scripts/smoke-custom-domain.sh verify
# Exit codes: 0 success, non-zero on any failed assertion.

set -uo pipefail

CMD="${1:-verify}"
HOST="${MJOLNIR_HOST:-${2:-root@45.76.77.97}}"

MJ=/opt/mjolnir/_build/prod/rel/mjolnir/bin/mjolnir
ROUTES=/etc/mjolnir/gateway.d/apps.toml
ACME=/var/lib/mjolnir-gateway/acme/fullchain.pem
STATE=/var/lib/mjolnir/deploy/smoke-baseline

fail=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }
note() { printf '  --    %s\n' "$*"; }

# `mjolnir rpc` needs RELEASE_NODE/RELEASE_COOKIE or it dies :noconnection, and there is
# no `mjolnir` on the host PATH -- hence sourcing the env and the absolute path.
rpc() { ssh "$HOST" "set -a; . /etc/mjolnir/env; set +a; $MJ rpc '$1'"; }

# The API authenticates remote callers; MJOLNIR_AUTH_BYPASS_LOCALHOST only exempts
# requests originating on the box. Curling from inside the ssh session sidesteps needing
# a token here.
api() { ssh "$HOST" "curl -sS --max-time 15 http://127.0.0.1:4000$1"; }

case "$CMD" in

verify)
  echo "==> Host: $HOST"

  apps_json="$(api /api/apps)" || { echo "could not reach API"; exit 1; }
  routes="$(ssh "$HOST" "cat $ROUTES")"

  # macOS ships bash 3.2 -- no mapfile, and empty-array expansion trips `set -u`.
  # A tmp file + while-read keeps this portable.
  tmp="$(mktemp -t mjolnir-smoke.XXXXXX)"
  trap 'rm -f "$tmp"' EXIT
  echo "$apps_json" | jq -r '.apps[] | select(.custom_domain != null) | "\(.app_name)\t\(.custom_domain)\t\(.backend)"' > "$tmp"

  if [ ! -s "$tmp" ]; then
    echo "No apps with a custom_domain registered — nothing to verify."
    exit 0
  fi

  while IFS="$(printf '\t')" read -r app domain backend; do
    [ -z "$domain" ] && continue
    echo "==> $app -> $domain"

    # 1. The reconciler emitted a route. Absent => the apex fell out of :gateway_apexes.
    if echo "$routes" | grep -q "\"$domain\""; then
      ok "route present (backend $backend)"
    else
      bad "NO route for $domain in $ROUTES — apex likely missing from :gateway_apexes; try: $0 restore-apex $domain"
    fi

    # 2. Origin serves. -k is required; see header.
    code="$(curl -sSk -o /dev/null -w '%{http_code}' --resolve "$domain:443:${HOST#*@}" "https://$domain/" --max-time 15 2>/dev/null)"
    [ "$code" = "200" ] && ok "origin 200" || bad "origin returned $code"

    # 3. Correct cert, asserted via SAN not issuer; see header.
    san="$(echo | openssl s_client -connect "${HOST#*@}:443" -servername "$domain" 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null)"
    case "$san" in
      *"DNS:$domain"*) ok "cert SAN covers $domain" ;;
      "")              bad "no cert served for $domain — gateway down?" ;;
      *)               bad "cert served does not cover $domain: $san" ;;
    esac

    # 4. The path a real visitor takes (through Cloudflare, publicly-trusted edge cert).
    code="$(curl -sS -o /dev/null -w '%{http_code}' "https://$domain/" --max-time 15 2>/dev/null)"
    [ "$code" = "200" ] && ok "public 200" || bad "public returned $code"
  done < "$tmp"

  # 5. ACME rate-limit tripwire.
  echo "==> ACME cache"
  fp="$(ssh "$HOST" "openssl x509 -in $ACME -noout -fingerprint -sha256" | sed 's/.*=//')"
  exp="$(ssh "$HOST" "openssl x509 -in $ACME -noout -enddate" | sed 's/.*=//')"
  base="$(ssh "$HOST" "cat $STATE/acme-fingerprint 2>/dev/null" || true)"
  if [ -z "$base" ]; then
    note "no baseline recorded (run '$0 snapshot'); expires $exp"
  elif [ "$fp" = "$base" ]; then
    ok "cert unchanged (expires $exp)"
  else
    bad "ACME cert CHANGED — gateway re-issued and burned LE quota. was $base now $fp"
  fi

  echo
  [ "$fail" -eq 0 ] && echo "All checks passed." || echo "FAILURES above."
  exit "$fail"
  ;;

snapshot)
  ssh "$HOST" "
    mkdir -p $STATE
    cp -a $ROUTES $STATE/apps.toml
    openssl x509 -in $ACME -noout -fingerprint -sha256 | sed 's/.*=//' > $STATE/acme-fingerprint
    echo 'baseline saved:'; ls -la $STATE"
  ;;

restore-apex)
  apex="${2:-}"
  [ -z "$apex" ] && { echo "usage: $0 restore-apex <apex>" >&2; exit 2; }
  # render_and_reload/1 takes :apexes explicitly, so this works even on an older
  # orchestrator build that cannot read MJOLNIR_GATEWAY_APEXES. put_env keeps it in place
  # for later reconciler runs until the next restart -- persist it in /etc/mjolnir/env to
  # make it durable.
  cur="$(rpc 'Application.get_env(:mjolnir, :gateway_apexes) |> inspect() |> IO.puts()' | tr -d '\r')"
  echo "current: $cur"
  new="$(echo "$cur" | sed "s/\]$/, \"$apex\"]/")"
  rpc "Application.put_env(:mjolnir, :gateway_apexes, $new)"
  rpc "Mjolnir.Gateway.Routes.render_and_reload(apexes: $new) |> inspect(pretty: true) |> IO.puts()"
  echo "NOTE: persist it — add $apex to MJOLNIR_GATEWAY_APEXES in /etc/mjolnir/env"
  ;;

restore-routes)
  ssh "$HOST" "
    [ -f $STATE/apps.toml ] || { echo 'no snapshot — run: $0 snapshot' >&2; exit 1; }
    cp -a $STATE/apps.toml $ROUTES
    systemctl reload mjolnir-gateway
    echo 'restored + reloaded:'; cat $ROUTES"
  ;;

*)
  echo "usage: $0 {verify|snapshot|restore-apex <apex>|restore-routes} [host]" >&2; exit 2 ;;
esac
