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
| Wildcard (`*.taskmaster.dev`) | **DNS-01** | Operator (or `_acme-challenge` CNAME into a worldtree zone we write). HTTP-01 cannot issue wildcards. `issue_manual` already prints the TXT records. |

The existing `[acme]` Cloudflare DNS-01 path stays worldtree-only. That token
must not be aimed at customer zones.

## Command

```
mj cert issue taskmaster.dev              # HTTP-01, install [[cert]]
mj cert issue --wildcard taskmaster.dev   # DNS-01; prints TXT; waits
```

Issuance runs **on the host** (API), not on the laptop. The Mac client only
POSTs `/api/certs/issue`. Challenge files live in
`/var/lib/mjolnir-gateway/http-01/<token>`.

## Beads

- `mjolnir-r7b3.1` gateway intercept
- `mjolnir-r7b3.2` `issue_http01`
- `mjolnir-r7b3.3` `mj cert issue`
