# VM Metadata and Generations

Two primitives that let an **external orchestrator** manage a subset of Mjolnir VMs safely:
opaque labels it can select on, and a fencing token it can use to make destructive writes safe
against concurrent change.

Mjolnir never interprets metadata. It is storage, selection, and a compare-and-swap — nothing more.

Motivating consumer: [`buzz-backend-mjolnir`](https://github.com/identikey/buzz-backend-mjolnir),
whose reconciliation loop must converge to at-most-one-live-instance per agent key.

---

## The three problems these solve

An orchestrator that creates VMs on our behalf needs to answer three questions, and getting any of
them wrong is a correctness bug rather than an inconvenience:

| question | mechanism |
|---|---|
| *Which VMs are mine?* | `metadata` + `GET /api/vms?metadata.k=v` |
| *Is **this** VM really the one I mean?* | exact-match read of a full identifier from `metadata` |
| *Has it changed since I looked?* | `generation` + `If-Match` on delete |

The second is not redundant with the first. A short selector (a truncated key, a name prefix) is
collision-*resistant*, not collision-*free*. Narrow with the cheap selector, then confirm against a
full identifier before acting.

---

## Metadata

An opaque `string => string` map, set at spawn and persisted with the VM record.

```bash
curl -X POST localhost:4000/api/vms -H 'content-type: application/json' -d '{
  "metadata": {
    "managed-by":  "buzz-backend-mjolnir",
    "agent-pubkey": "3bf0c63f...",
    "schema-version": "1"
  }
}'
```

**Bounds** (enforced at the API boundary, `Mjolnir.API.Validation.validate_metadata/1`): at most 32
keys, keys ≤128 bytes, values ≤512 bytes, no empty keys, and **no control characters** in keys or
values. Metadata is echoed into JSON responses and written to a file on disk; a caller has no
business smuggling a newline into either.

### Metadata is set at spawn, deliberately

It travels with the *first* record write rather than being applied afterwards. A create-then-label
sequence has a window in which a VM exists unlabelled, and a crash inside that window strands a VM
that its creator can no longer recognise as its own. Closing that window is the whole point.

### Metadata survives a rebuild

`Mjolnir.VM.build_running_record/1` constructs a fresh record on every persist and on every resume.
`StateStore.put/1` carries metadata forward when the incoming record has none, so an ordinary VM
reboot does not silently strip an orchestrator's labels. To *change* labels, pass them explicitly or
use `StateStore.merge_metadata/2`.

### Filtering

```bash
mj list --filter managed-by=buzz-backend-mjolnir
mj list --filter managed-by=buzz-backend-mjolnir --filter agent-pubkey=3bf0c63f...

# equivalently
GET /api/vms?metadata.managed-by=buzz-backend-mjolnir&metadata.agent-pubkey=3bf0c63f...
```

Every pair must match (AND). An empty selector matches everything, so an unfiltered list behaves
exactly as before. Stranded and failed records are filtered on the same terms as live VMs, so a
selector cannot make a VM disappear from the list merely because its GenServer died.

`mj list --filter` **rejects** a malformed `--filter` rather than dropping it. Silently ignoring a
selector would widen a `mj list --filter … | xargs mj kill` pipeline from "my VMs" to "every VM".

---

## Generations

Every record carries a monotonic `generation`, starting at 1 and incremented by `StateStore.put/1`
on **every** write.

The counter is owned by the store, never by the caller. That is not stylistic: callers such as
`build_running_record/1` construct a fresh struct on every persist, so a caller-supplied generation
would reset to 1 each time and silently void the guarantee. `put/1` ignores whatever the passed
record carries and assigns `previous + 1`.

### Compare-and-delete

```bash
# read
GET /api/vms?metadata.agent-pubkey=3bf0c63f...   →  [{ "id": "…", "generation": 7, … }]

# act, fenced to exactly that observation
DELETE /api/vms/<id>   If-Match: 7
```

| outcome | meaning |
|---|---|
| `200` | deleted |
| `409 generation_conflict` | the record is at a different generation — something changed since the read that authorized this delete |
| `400` | `If-Match` present but not a positive integer |
| *(header absent)* | unconditional delete, exactly as before |

On `409`, **re-read and decide again**. Never retry blindly: the conflict is the signal that the
premise of the decision no longer holds.

At the store layer the same contract is `StateStore.delete_if_match/2`. Delete-of-absent is
**success**, so a delete retried after a crash is not an error.

---

## Elixir API

```elixir
StateStore.list_by_metadata(%{"managed-by" => "buzz-backend-mjolnir"})
StateStore.merge_metadata(uuid, %{"phase" => "draining"})   # {:ok, record} | :not_found
StateStore.delete_if_match(uuid, generation)                # :ok | {:error, :conflict}
```

---

## Schema migration, in both directions

The record schema went from **v1 to v2**. Version skew cuts two ways, and quarantine — which
*renames* the file — is the wrong answer to both.

### Older file, newer binary (a deploy)

v1 files are still read: `metadata` defaults to empty, `generation` to 1, and the record is
rewritten as v2 on its next write. `@readable_schema_versions` in `Mjolnir.StateStore.Record` is the
list to extend when the schema next moves.

A malformed `generation` likewise reads as 1 rather than failing the load — a record we cannot
fence is still a record we must not lose.

### Newer file, older binary (a **rollback**)

This is the more dangerous direction, because a rollback is what you do *during* an incident.

A record whose `schema_version` we do not speak is **intact** — the binary that wrote it can still
read it. So it is **left exactly where it is**:

- the file is not moved, not rewritten, not deleted;
- the UUID is held back from writes — `put/1`, `delete/1`, `delete_if_match/2` and
  `merge_metadata/2` all return `{:error, :record_unreadable}`, so the older binary cannot
  overwrite a record it could not read;
- it is listed by `StateStore.unreadable/0` and reported by `mj doctor` as
  `state_records: degraded` with the UUIDs and the fix.

**The fix is to roll forward.** Because the bytes were never touched, the newer build reads them
back unharmed.

> Quarantining here would have been an outage of our own making: quarantine renames the file, so
> rolling *forward* again would not find it either. The rollback itself would have destroyed the
> data.

### What still gets quarantined

Files nobody can read: invalid JSON, a missing or malformed `schema_version`, missing required
fields. Those are moved to `<state_dir>/quarantine/` and logged, never deleted. That is the case
quarantine was designed for and it is unchanged.

---

## What this deliberately does not do

- **No server-side authorization on metadata.** Ownership is still `owner_id`. Metadata is a label,
  not a capability, and must never be treated as one.
- **No uniqueness constraint.** Two VMs may carry identical metadata. Enforcing at-most-one is the
  orchestrator's reconciliation job, which is what the generation fence exists to make safe.
- **No indexing.** `list_by_metadata/1` is a linear scan over the ETS-cached record set, which is
  the right shape at Mjolnir's VM counts. Revisit if that stops being true.
