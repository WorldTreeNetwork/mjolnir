# Runbook: Migrate Zine to `secrets_mode: :managed`

> **Status: NOT EXECUTED as of 2026-07-19.** This is a prepared procedure, not a record of work
> done. Verified against the prod host: the escrow directory `/var/lib/mjolnir/escrow/` is
> **empty**, there is no `/var/lib/mjolnir/zine-secrets.json`, `Deploy.Registry` is **empty**,
> and Zine's running VM reports **`secrets_mode: none`**. Zine's SMTP credentials are therefore
> still wherever they were before this migration was written.
>
> Note also that Zine is **hand-provisioned** — it is not currently started via
> `Deploy.Runtime`, so Step 2 below describes the *first* time that path would be used for it,
> not a change to an existing automated deploy. Expect to shake out first-run issues.

Move Zine's sensitive email (SMTP) credentials out of the app image / unit env
and into a **host-escrowed LUKS volume** so they are encrypted at rest, kept off
the data volume, and survive dormancy/wake. Background:
[`docs/secrets-architecture.md` → Managed Mode](../secrets-architecture.md#managed-mode-host-escrowed-secrets).

> **Trust model.** `:managed` is *not* zero-knowledge — the host can read the
> creds (it injects them). This buys: ciphertext-at-rest, off-data-volume
> passphrase, opaque snapshots/backups, scale-to-zero with transparent wake. It
> does **not** survive host compromise. Accepted trade for now.

## How Zine runs (context)

Zine is a `Deploy.Runtime` service VM (the `mj deploy` PaaS layer): built into a
`release_snapshot` by `Deploy.Builder`, booted by `Deploy.Runtime.start/4`,
fronted by the gateway at its `web_url`. Each deploy spawns a **fresh** service
VM from the release snapshot and cuts over (the previous VM is stopped).

Consequences that shape this migration:

- `secrets_mode` is fixed at spawn — there is **no in-place conversion**. You
  migrate by making the **next deploy** spawn the service VM as `:managed`.
- The release snapshot is built from app code and contains **no LUKS volume**, so
  every deploy's VM creates the volume fresh → **you re-supply the creds on every
  deploy**. Store them once on the host; the deploy reads + injects them.
- Within one deploy generation, dormancy→wake restores the volume transparently
  (escrow passphrase + dormancy snapshot). Deploy cutover kills the old VM, which
  auto-purges its escrow entry — no stale escrow accumulates.

## Prerequisites (already satisfied as of 2026-06-26)

- [x] Code with `:managed` deployed to the server (commits `42e16aa`, `938f711`).
- [x] Guest agent rebuilt with `full + iroh` (provides the vsock `inject_secrets`
      handler). Verified: dormancy roundtrip PASS on the server.
- [x] Base image supports LUKS (cryptsetup + DM_CRYPT) — confirmed by the
      roundtrip creating/opening a real volume.

If you re-pull or rebuild the guest agent, re-run `just deploy` so the injected
agent has the `inject_secrets` handler.

---

## Step 1 — Stash Zine's creds on the host (off the data volume)

Write the creds to a `0600` file under `/var/lib/mjolnir/` (NOT under
`/var/lib/mjolnir/btrfs`, the data volume). The deploy reads this file and passes
it as the spawn-time `secrets` payload. Type the real values into the heredoc so
they never land in shell history elsewhere:

```bash
ssh root@45.76.77.97 'umask 077; cat > /var/lib/mjolnir/zine-secrets.json' <<'JSON'
{
  "SMTP_HOST": "smtp.example.com",
  "SMTP_PORT": "587",
  "SMTP_USER": "zine@identikey.io",
  "SMTP_PASS": "REPLACE_ME"
}
JSON
ssh root@45.76.77.97 'chmod 600 /var/lib/mjolnir/zine-secrets.json && ls -l /var/lib/mjolnir/zine-secrets.json'
```

> Keys must be valid env names (`[A-Za-z_][A-Za-z0-9_]*`). Values are strings.
> The app reads them as ordinary env vars (`process.env.SMTP_PASS`, etc.).

## Step 2 — Deploy Zine as `:managed`

Fold `secrets_mode: :managed` + the creds into the **`Deploy.Runtime` spawn_opts
only**. Do **not** put them on `Deploy.Builder` (that would bake a LUKS volume —
keyed to the throwaway build VM's passphrase — into the release snapshot).

Run against the live node via `rpc` (sources the release env for node/cookie):

```bash
ssh root@45.76.77.97 'set -a; . /etc/mjolnir/env; set +a; \
  /opt/mjolnir/_build/prod/rel/mjolnir/bin/mjolnir rpc "
    creds = \"/var/lib/mjolnir/zine-secrets.json\" |> File.read!() |> Jason.decode!()
    plan = %{port: 3000, start_command: \"<ZINE_START_COMMAND>\"}
    {:ok, res} = Mjolnir.Deploy.Runtime.start(
      \"zine\",
      \"<CURRENT_RELEASE_SNAPSHOT>\",
      plan,
      spawn_opts: %{secrets_mode: :managed, secrets: creds}
    )
    IO.puts(\"url=\" <> res.url)
    IO.puts(\"service_vm_id=\" <> res.service_vm_id)
  "'
```

Fill in:

- `<CURRENT_RELEASE_SNAPSHOT>` — the release snapshot you're deploying (the same
  one your normal deploy uses; check `GET /api/snapshots`).
- `<ZINE_START_COMMAND>` and `port` — Zine's existing start command + port (the
  same `plan` your current deploy uses; e.g. `node build/index.js`, port 3000).
- If you deploy through `Deploy.Builder` (fresh build), pass `spawn_opts` to the
  **`Runtime.start` call only**, leaving `Builder.build/3` opts unchanged.

`Runtime.start` spawns the managed VM (creates LUKS, injects creds, renders
`/run/mjolnir/secrets.env`), installs the unit, registers it, and **cuts over**
(stops the previous non-managed Zine VM).

---

## Step 3 — Verify

```bash
API=localhost:4000
# 1. New service VM is running + has its gateway URL
ssh root@45.76.77.97 "curl -s $API/api/vms" | python3 -m json.tool

# 2. App process actually sees the secret (login-shell sourced it).
#    Replace <ID> with the new service_vm_id from Step 2.
ssh root@45.76.77.97 "curl -s -X POST $API/api/vms/<ID>/exec \
  -H 'content-type: application/json' \
  -d '{\"command\":\"printenv SMTP_USER\"}'"   # expect the value, not blank

# 3. Passphrase is escrowed off the data volume, 0600
ssh root@45.76.77.97 'ls -l /var/lib/mjolnir/escrow/<ID>'

# 4. End-to-end: hit the site and trigger an email path; confirm SMTP works.
```

If `printenv` is blank: the app started before the secret landed. Restart the
unit inside the VM (`systemctl restart <app>.service`) — the login-shell
ExecStart re-sources `/run/mjolnir/secrets.env`. (Ordering normally prevents
this: spawn injects secrets before the unit is installed.)

> **Do not** add `EnvironmentFile=/run/mjolnir/secrets.env` to the unit. The file
> is `export KEY='value'` (shell), which systemd's `EnvironmentFile` cannot
> parse. The login-shell `ExecStart=/bin/sh -lc '…'` is the correct path and is
> already in the generated unit.

## Step 4 — Remove the old plaintext creds (after verifying)

Once managed is confirmed working, scrub the creds from wherever they lived
before (committed `.env` in the repo/build, `Environment=` lines in a unit, etc.)
so the snapshot/image no longer carries plaintext. Rotate the SMTP password if it
was ever committed to git history.

---

## Rollback

The previous (non-managed) VM was stopped during cutover, but its rootfs is
preserved and the prior release snapshot still exists. To revert: re-run
`Runtime.start` with the **previous** release snapshot and **without**
`spawn_opts` (or with `secrets_mode: :none`). Then delete the escrow if you want
it gone: `rm -f /var/lib/mjolnir/escrow/<ID>`.

## Operational notes

- **Re-seed each deploy.** Every deploy reads `zine-secrets.json` and re-injects.
  Keep that file as the source of truth; update it to rotate creds, then redeploy.
- **Rotation.** Change `zine-secrets.json` → redeploy. The new VM gets a new
  passphrase + a fresh volume seeded with the new values; the old VM (and its
  escrow) is torn down on cutover.
- **Dormancy.** If Zine scales to zero and wakes, the host re-opens the volume
  from the dormancy snapshot using the escrowed passphrase — no re-seed needed,
  no human in the loop.
- **Escrow lifecycle.** Kill/cutover deletes the escrow entry; dormancy keeps it.
  Expect exactly one escrow file per *currently running* managed VM.
- **Backups.** A `secrets.luks` in any snapshot is ciphertext; the passphrase is
  only in `/var/lib/mjolnir/escrow/`. Back up the escrow dir separately (and
  protect it) if you want snapshot backups to be restorable elsewhere.
