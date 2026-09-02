# Secrets consumption & lifecycle — lessons from Tatastu's `CredentialSource`

**Status:** Design note (2026-09-02). Not an ADR yet; each numbered item is
small enough to become its own change when picked up.
**See also:** [`secrets-architecture.md`](secrets-architecture.md) (the
delivery layer these notes build on), `docs/decisions/0008-secret-tokenator.md`
(foreign secrets; orthogonal — this note is about OUR secrets after delivery).

## Why this note exists

Tatastu (the first external agent workload targeting Mjolnir; see its
`openspec/changes/add-mjolnir-cloud-backend/`) integrates against our secrets
layer and brings a credential contract, `CredentialSource`, that was designed
for exactly the machine Mjolnir dormancy creates: **an unattended VM holding
live credentials with nobody watching**. Mjolnir's delivery security is ahead
of Tatastu's (E2E Iroh injection, host-blind option, LUKS at rest, one-shot
guard). What `CredentialSource` has that we don't is a theory of the OTHER end
of a secret's life: who may read it, how its death is noticed, and who cleans
up the body. Dormancy turns those from hygiene into load-bearing.

Five lessons, in value order. Sources are real code:
`src/main/lib/engine/headless/contract.ts` (`CredentialSource`,
`ProviderCredential`), `remote-credential.ts` (expiry-where-a-human-is),
and Tatastu's `remote-compute` spec.

## 1. Consumption should be an explicit read at one seam, not ambient env

Today every vsock `exec` auto-sources `/run/mjolnir/secrets.env`, so every
command — including anything an AI agent decides to run — inherits every
secret. Our own Layer-5 story is "AI agents run with full system access,
safely sandboxed"; auto-sourcing means the sandbox holds but every child of
the agent is inside it *with the keys*. `CredentialSource`'s rule: the read
happens in exactly one auditable place, and env inheritance never carries it.

**Proposal:** per-secret delivery mode — `env` (today's behavior, right for
classic apps) or `file` (exists already as `files/`, but only as a place, not
a mode) — plus a per-exec `secrets: false` opt-out. Agent workloads then keep
secrets out of `process.env` entirely and read `/secrets/files/<name>` at the
moment of use. Tatastu's tasks 2.1/2.2 want exactly this and currently have
to dodge the sourcing wrapper by hand.

## 2. Two strings with different lifetimes are two different types

Tatastu's `ProviderCredential` is a union (`api-key` | `oauth-token`) because
both are strings and only one expires with no refresh path — a difference the
type system is the only durable place to record. Our entries are opaque
`KEY=VALUE`: nothing knows that `ANTHROPIC_TOKEN` dies in 90 days while
`DATABASE_URL` is forever.

**Proposal:** optional per-entry metadata in the volume's `metadata.json` —
`kind`, `expires_at` — written at `set_env`/`push_env`/file-put time. Pure
bookkeeping; everything below stands on it.

## 3. Expiry must surface where a human is — dormancy makes this acute

Tatastu's `remote-credential.ts` exists for one insight: a credential failure
on an unattended machine is invisible, so remaining lifetime is tracked and
warned about on the surface a person actually looks at, BEFORE anything
depends on it (their warning window is a week — deliberately wider than the
provider's own three days, because the failure lands where nobody is
looking). Our version of that machine is a dormant VM: asleep two months,
token lapses mid-nap, wake-on-message boots a workload that fails with a
generic app error.

**Proposal:** with (2)'s metadata, surface expiring/expired entries in
`mj secrets status`, `mj list --dormant`, and the API; optionally
refuse-with-reason a wake whose required secret is already dead (Tatastu's
pattern: refused before allocation, surfaced as a plain connection problem,
never discovered by the workload).

## 4. Expired ciphertext is pure liability — delete it

From Tatastu's spec, verbatim-worthy: a credential past its expiry is deleted
rather than retained, "because a credential that can no longer authenticate
has no remaining purpose and keeping it only widens what a future compromise
would expose." We retain dormant snapshots' LUKS blobs and escrowed
passphrases indefinitely.

**Proposal:** guest agent prunes expired entries on wake (it already opens
the volume then); escrow TTL for VMs dormant beyond a stated horizon. Shrinks
what a leaked escrow dir + snapshot pair is worth.

## 5. Typed absence beats a mystery env var

Tatastu's `getGitCredential` returns `null` for "no credential, and that's
fine" (public repo) and throws for "misconfigured" — the two failure modes an
operator actually needs to tell apart. Our apps discover a missing secret as
an unset env var, i.e. as an application-level mystery.

**Proposal:** a guest-agent "get named secret" call returning value or a
typed miss. This is also the natural API for (1)'s file mode, so they are one
change, not two.

## What this note is not

Not a critique of the delivery layer — injection, custody modes, and at-rest
crypto are the strong half and stay as they are. Not the tokenator — ADR 0008
is about foreign secrets crossing trust boundaries; this is about our own
secrets aging in place. And not urgent-all-at-once: (1) unblocks Tatastu's
agent image cleanly, (2)+(3) are one small change, (4)+(5) can trail.
