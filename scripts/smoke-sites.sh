#!/usr/bin/env bash
# Smoke test for the IdentiKey Sites publish→serve flow.
#
# Prerequisites:
#   - Mjolnir API running locally on $MJOLNIR_API (default http://localhost:4000)
#   - mix, just, jq, curl installed
#
# What it does:
#   1. Generates a fresh IdentiKey keypair (writes to a tmp file)
#   2. Computes its fingerprint
#   3. Registers the identity/pubkey self-attestation record
#   4. Publishes a tiny 2-file site
#   5. Serves both files back, asserts content matches
#   6. If `mix mjolnir.sites.alias` is available (Phase 1.5+), adds an alias,
#      hits the resolver, asserts the lookup succeeds, removes it, asserts 404
#
# Run: scripts/smoke-sites.sh
# Exit codes: 0 success, non-zero on any failed assertion.

set -euo pipefail

API="${MJOLNIR_API:-http://localhost:4000}"
TMP="$(mktemp -d -t mjolnir-smoke.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

KEYPAIR_FILE="$TMP/keypair.json"
SITE_DIR="$TMP/site"
SITE_NAME="smoketest"

echo "==> API: $API"
echo "==> Tmp: $TMP"

# --- 1-2. Generate keypair + compute fingerprint via IEx eval ---
echo "==> Generating IdentiKey keypair"
mix run -e "
  kp = Mjolnir.Sites.IdentiKey.gen_keypair()
  fp = Mjolnir.Sites.IdentiKey.fingerprint(kp)
  File.write!(\"$KEYPAIR_FILE\", Mjolnir.Sites.IdentiKey.keypair_to_json(kp))
  IO.puts(fp)
" --no-start | tail -1 > "$TMP/fp"
FP="$(cat "$TMP/fp")"
echo "    fp=$FP"

# --- 3. Register identity/pubkey ---
echo "==> Registering identity"
# The identity record is a JSON envelope with the pubkey field.
mix run -e "
  kp = Mjolnir.Sites.IdentiKey.keypair_from_json!(File.read!(\"$KEYPAIR_FILE\"))
  record = Jason.encode!(%{pubkey: Base.encode64(kp.ed25519_public)})
  resp = Req.put!(
    \"$API/api/sites/$FP/identity/pubkey\",
    body: record,
    headers: [{\"content-type\", \"application/octet-stream\"}]
  )
  IO.puts(\"identity register: \" <> Integer.to_string(resp.status))
" --no-start || echo "    (skipped — endpoint may not exist; identity is bootstrapped via direct SecretStore.put)"

# --- 4. Build a tiny site and publish ---
echo "==> Building tiny site"
mkdir -p "$SITE_DIR"
cat > "$SITE_DIR/index.html" <<'HTML'
<!doctype html>
<title>smoke</title>
<h1>hello from mjolnir sites</h1>
HTML
cat > "$SITE_DIR/style.css" <<'CSS'
body { font-family: sans-serif }
CSS

echo "==> Publishing site"
mix mjolnir.sites.publish "$SITE_DIR" \
  --identikey-fp "$FP" \
  --site "$SITE_NAME" \
  --base-url "$API" \
  --sequence 1 \
  --keypair-file "$KEYPAIR_FILE"

# --- 5. Serve files back ---
echo "==> Serving /index.html back"
got="$(curl -sf "$API/api/sites/$FP/$SITE_NAME/files/index.html")"
if echo "$got" | grep -q "hello from mjolnir sites"; then
  echo "    PASS: /index.html content matches"
else
  echo "    FAIL: unexpected /index.html body"
  echo "    body: $got"
  exit 1
fi

echo "==> Serving /style.css back"
got="$(curl -sf "$API/api/sites/$FP/$SITE_NAME/files/style.css")"
if echo "$got" | grep -q "font-family: sans-serif"; then
  echo "    PASS: /style.css content matches"
else
  echo "    FAIL: unexpected /style.css body"
  exit 1
fi

# --- 6. Alias flow (Phase 1.5+) ---
if mix help mjolnir.sites.alias > /dev/null 2>&1; then
  echo "==> Phase 1.5 alias flow detected; exercising"
  ALIAS_HOST="blog.smoke.test"

  mix mjolnir.sites.alias add "$ALIAS_HOST" \
    --identikey-fp "$FP" \
    --site "$SITE_NAME" \
    --base-url "$API" \
    --keypair-file "$KEYPAIR_FILE" \
    --sequence 1

  resolved="$(curl -sf "$API/api/sites/aliases/lookup?host=$ALIAS_HOST")"
  if echo "$resolved" | jq -e --arg fp "$FP" --arg s "$SITE_NAME" \
       '.identikey_fp == $fp and .site_name == $s' > /dev/null; then
    echo "    PASS: alias resolves to ($FP, $SITE_NAME)"
  else
    echo "    FAIL: alias did not resolve correctly"
    echo "    body: $resolved"
    exit 1
  fi

  mix mjolnir.sites.alias remove "$ALIAS_HOST" \
    --identikey-fp "$FP" \
    --site "$SITE_NAME" \
    --base-url "$API" \
    --keypair-file "$KEYPAIR_FILE" \
    --sequence 9999999999

  status="$(curl -s -o /dev/null -w '%{http_code}' "$API/api/sites/aliases/lookup?host=$ALIAS_HOST")"
  if [ "$status" = "404" ]; then
    echo "    PASS: alias removal returns 404 on lookup"
  else
    echo "    FAIL: expected 404 after remove, got $status"
    exit 1
  fi
else
  echo "==> Phase 1.5 alias task not present yet; skipping alias flow"
fi

echo "==> All assertions passed."
