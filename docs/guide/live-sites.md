# Live IdentiKey Sites

Operator inventory. Fingerprints are Blake3 of the raw ED25519 pubkey
(`IdentiKey.fingerprint/1`, Elixir-style base58). Rebuild on the laptop,
publish with `mj`. Do not commit keypair files.

| Site | Domain(s) | Blake3 fingerprint | Source | Publish dir | Keypair |
|---|---|---|---|---|---|
| `wtnf` | worldtree.network | `ESQdLp4quU2gH4rn6GXzdm93G4SrkME58dJXxHJMrc32` | `~/work/WorldTree/wtnf-web` | `build/` (SvelteKit `adapter-static`) | `~/.ssh/wtnf-identikey.json` (host `/etc/mjolnir/wtnf-identikey.json`) |
| `lightning-mesh` | lightning.worldtree.network | `9m9YdqCFcQKGtLzAk2rKYMLK9xw9zERpJiEqWk3NAfaQ` | `~/work/WorldTree/lightning-mesh/docs-web` | `build/` (`./scripts/publish.sh`) | `~/.config/mjolnir/identikey.json` |
| `intentional` | intentional.agency, www.intentional.agency | `DkDaveebrZXCEoqxcFAJDLu7o2qqRm3zuBDfyGFCDcPZ` | `mjolnir/sites/intentional-agency/` | the folder itself | `~/.config/mjolnir/intentional-identikey.json` (host `/etc/mjolnir/intentional-identikey.json`) |
| `park` | park.worldtree.network | `5N6QezYt2LhQyrNDywUvsYoaVJEC2xWDV7QTnfGRH6rw` | `mjolnir/sites/park/` | the folder itself | `~/.config/mjolnir/park-identikey.json` (host `/etc/mjolnir/park-identikey.json`) |

`~/work/WorldTree/intentional.agency/` is notes, not the published tree.
Skip `e2e` / `e2e2` / `prunetest` — fixtures, not materialized.

## Republish

`--identikey-fp` must match `IdentiKey.fingerprint/1` of the keypair.
`--sequence` must strictly increase (unix epoch seconds is fine).

```bash
# wtnf
cd ~/work/WorldTree/wtnf-web && bun run build
mj sites publish ./build --site wtnf \
  --keypair-file ~/.ssh/wtnf-identikey.json \
  --identikey-fp "$WTNF_FP" \
  --sequence "$(date +%s)"

# lightning-mesh
cd ~/work/WorldTree/lightning-mesh/docs-web && ./scripts/publish.sh

# park / intentional — static HTML in this repo
mj sites publish sites/park --site park \
  --keypair-file ~/.config/mjolnir/park-identikey.json \
  --identikey-fp "$PARK_FP" \
  --sequence "$(date +%s)"
mj sites publish sites/intentional-agency --site intentional \
  --keypair-file ~/.config/mjolnir/intentional-identikey.json \
  --identikey-fp "$INTENTIONAL_FP" \
  --sequence "$(date +%s)"
```

Then bind domains (`mj domain set <site> <fqdn> --keypair-file …`).

## Remint (hash algorithm change)

A fingerprint algorithm change writes a **new** keyspace path. The
gateway alias index (`@sites/keyspace/_index/aliases/<fqdn>`) still
points at the old fp, and `PUT` of the new alias is
`alias_already_claimed`. After the new snapshot is materialized, rewrite
those JSON files as root:

```json
{"fp":"<new-blake3-fp>","site":"<site-name>"}
```

wtnf Forgejo Actions (`wtnf-web/.forgejo/workflows/deploy.yml`) uses
`vars.IDENTIKEY_FP` and `secrets.MJOLNIR_SITES_TOKEN`. The token is
bound to a fingerprint — remint the token when the fp changes.
