# On-demand ACME for CNAME'd custom domains

Epic: `mjolnir-r7b3`. Dated 2026-08-16.

## Why CNAME to `*.vm.worldtree.network` is not enough

The ticket URL cert is `*.vm.worldtree.network`. A CNAME of `taskmaster.dev`
to `…-5173.vm.worldtree.network` still presents SNI/Host `taskmaster.dev`.
Browsers want a SAN for **that** name. The worldtree wildcard never covers it.

## What we can spin up at will

| Want | Challenge | Works when |
|---|---|---|
| Exact name (`taskmaster.dev`) | **HTTP-01** | Name already reaches this gateway (`A` or `CNAME`). LE follows the CNAME to `:80`. We intercept `/.well-known/acme-challenge/` **before** proxying to the VM. |
| Wildcard (`*.taskmaster.dev`) | **not in v1** | HTTP-01 cannot issue wildcards. There is no `--wildcard` flag. `--manual` (DNS-01 TXT) stays on the gateway binary for operators; it is not wired through `mj cert issue`. |

The existing `[acme]` Cloudflare DNS-01 path stays worldtree-only. That token
must not be aimed at customer zones.

## Command

```
mj cert issue taskmaster.dev              # HTTP-01, install [[cert]]
mj cert ls                                # installed hosts (no PEMs)
```

`*.` is refused at clap and at `POST /api/certs/issue`. v1 has no
`--wildcard`.

Issuance runs **on the host** (API), not on the laptop. The Mac client only
POSTs `/api/certs/issue`. The API fires a one-shot:

```
systemd-run --wait --collect --uid=mjolnir --gid=mjolnir \
  /usr/local/bin/mjolnir-gateway cert issue \
    --domain <fqdn> --email <acme_email> \
    --out /var/lib/mjolnir-gateway/issued/<slug> \
    --http01-dir /var/lib/mjolnir-gateway/http-01
```

`mjolnir.service` has `ProtectSystem=strict` and cannot write the http-01
dir. Do **not** add `ReadWritePaths` (that restarts the BEAM and kills VMs).
The one-shot runs as the `mjolnir` user; the **running** gateway already
serves challenges from that dir.

After LE returns, `Mjolnir.Gateway.Certs.ensure/2` installs `[[cert]]` and
reloads the gateway. PEMs never leave the host.

## Beads

- `mjolnir-r7b3.1` gateway intercept
- `mjolnir-r7b3.2` `issue_http01`
- `mjolnir-r7b3.3` `mj cert issue` (HTTP-01 only; no `--wildcard`)
