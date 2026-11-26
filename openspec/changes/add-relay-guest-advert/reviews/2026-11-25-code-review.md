# Code review: add-relay-guest-advert

> **ADVISE:** send-back
> **READER:** claude-code/claude-opus-5-5
> **SPAWN:** orchestrator review sub-agent (long-lived contract reviewer, read-only), session 2026-11-25

Scope: `a789d91` (recorded conditions) and `8d50e04` (build) on `main`. The other commits in `abd9e85..8d50e04` are unrelated work (keyframes, open-room spikes, the relay scale harness) and were not reviewed. Author: Codex `gpt-6.2-sol`. Node `mjolnir-rurh.6`.

## Verdict

**Send-back on one required fix (F1).** Everything else is correct and well tested. After F1 lands with its test, this can be folded once the owner's production gate is handled. The fix is small and a re-review can be limited to `lib/mjolnir/relay/locator.ex` and its test.

## Findings by severity

### F1 — Important: the root controller reads an unprivileged, internet-facing service's file without limits

`lib/mjolnir/relay/locator.ex:23` runs `File.read(locator_path)` on `/run/mjolnir-relay/locator.json`. Systemd creates that directory with `RuntimeDirectory=mjolnir-relay`, owned by `User=mjolnir-relay` (`systemd/mjolnir-relay.service:15,22`). The relay process terminates public QUIC and WebTransport on UDP 443. The controller is root and calls `Locator.read/0` inside `complete_guest_setup/1` (`lib/mjolnir/vm.ex:2881`) on every boot and disk resume.

`File.read/1` follows symlinks, opens FIFOs and devices, and reads to EOF. The content checks (hostname match, 64-hex id) run only after the read, so they protect confidentiality but not availability.

- **Failing input (reproduced on this Mac against `8d50e04`, via `Locator.read(env_path: …, locator_path: …)` in a task):**
  - `locator.json` replaced by a FIFO: still blocked after 3 s. Every guest boot and resume would hang in its VM process.
  - `locator.json` a symlink to `/dev/zero`: still blocked after 3 s while memory grows without limit in the root BEAM. That puts the whole controller at OOM risk.
- **Who can do it:** anyone who compromises the relay process. The relay user's sandbox exists to contain exactly that. Before this change, that user had no path into the controller.
- **Fix:**
  - `File.lstat(locator_path)` must return `type: :regular` with `size` ≤ 4096. This rejects symlinks, FIFOs, devices and large files before any open.
  - Read with a byte limit: `File.open(path, [:read, :binary])` plus `IO.binread(dev, 4097)`, refusing more than 4096 bytes.
  - Run the open and read in a `Task` with a short timeout, for example 250 ms. On timeout use `Task.shutdown(t, :brutal_kill)` and return `%{}`. This closes the gap between the check and the read, where a regular file could be swapped for a FIFO.

  Every failure returns `%{}`, so behaviour stays "both fields absent". `relay.env` is root-owned in `/etc` and does not need this.
- **Test:** add resolver cases for a symlink (to a valid document as well, so the test shows symlinks are refused rather than invalid), a FIFO (must return `%{}` within a bounded time) and a 4097-byte file. Each must fail against the current `File.read`.

### F2 — Low: the guest-setup wiring has no unit test (carry; no fix required)

I reverted `lib/mjolnir/vm.ex:2881` to `%{"blob_door_url" => blob_door_url}` and the full suite still passed (1,979). Only the open EYES box covers the line that connects the resolver to `configure_identity`. That is acceptable for a one-line wire, but keep the EYES box as the evidence before fold.

### Notes (no change required)

- **Relay startup order changed slightly** (`native/mjolnir_relay/src/main.rs`). SIGTERM and SIGINT handlers are now registered before `notify_ready()`. Before, they were registered inside a task spawned after it, so a SIGTERM in that gap killed the process under the default signal action, skipping drain. This is an improvement and is correct, but it is a behaviour change in a live binary. A second change: `clear_locator(&locator)?` at startup now aborts the start if an existing `locator.json` cannot be removed, for example if it is a directory or the directory is not writable. Under systemd the runtime directory is fresh on every start, so this cannot trigger there.
- **Locator file mode is `0600`** (`tempfile::NamedTempFile` default), owned by `mjolnir-relay`. Only root reads it, so this is correct. The runbook does not state a mode, and nothing reads it as another user.
- `tempfile` moved from dev-dependencies to dependencies. That is required for the rename write.

## Contract checks

1. **Relay locator.** Written with temp-file plus rename in the same directory, after `mount_iroh` and before `notify_ready()`. It contains exactly `{"host","endpoint_id"}` from the loaded settings and the bound endpoint. It is removed at drain (`drain_then_stop`), removed again after `relay.run()` returns or fails, and an old file is discarded at startup. After a crash, systemd's `RuntimeDirectoryPreserve=no` (the builder reports the installed unit shows it) and the startup discard cover the next run. The sandbox allows the write, with `keys.active` as precedent. No unit-file change.
2. **Controller.** Inputs are read afresh at each `complete_guest_setup/1`. Missing, unreadable, malformed, mismatched or disabled inputs all give `%{}`. Both `Locator.read` and `maybe_put_relay_locators` (`lib/mjolnir/vsock/protocol.ex:222-230`) enforce both-or-neither. Only the two strings are added. The pair goes in `locators` only, not at the top level, and the guest flattens it. The disk-resume versus memory-thaw distinction is true to the code: `attach_thawed/3` (`vm.ex:3286`) never calls identity setup. It is documented in the spec, the catalog and the runbook, including rebooting a thawed guest after a compromise reset. Oversized files, symlinks and FIFOs fail (F1).
3. **`mj relay token`** (`native/mjolnir_client/src/relay.rs`):
   - Session and request: uses the saved or refreshed session via `resolve_token`, the same path as `api_client`, and `config::resolve_api`. Redirects are disabled. The body is `{}`.
   - Output: stdout gets the token plus a newline, or the raw body bytes with `--json`.
   - Errors: no body, token or bearer appears in any error. Hints for 401 (`mj login`), 403 (`relay:join`) and 503 (unconfigured). Every failure exits nonzero with empty stdout.
   - Deferred and untouched: no `--ttl`, no `--kind`. `git diff abd9e85 8d50e04 -- lib/mjolnir/relay/mint.ex lib/mjolnir/api/router.ex` is empty.
4. **Tests fail without the code.** Mutations in scratch copies, each reverted:

   | Mutation | Result |
   |---|---|
   | Locator: drop the hostname-equality check | `does not reuse old locators after config changes` fails |
   | Locator: drop the `ENABLED == "true"` match | same test fails |
   | Protocol: drop `maybe_put_relay_locators` | `configure_identity allows only the public relay pair` fails |
   | Relay: drop `clear_locator` at drain (Linux, user namespace) | `publishes_the_bound_identity…withdraws_it_at_drain` fails at `:118` |
   | Relay: drop the startup discard (Linux) | `failed_start_discards_an_old_locator` fails at `:148` |
   | mj: drop the 403 hint (Linux) | `reports_distinct_http_hints_without_response_bodies` fails |
   | mj: re-serialize `--json` instead of passing bytes | `prints_the_original_json_bytes_including_extensions` fails |
   | vm.ex: revert the wiring line | **nothing fails** (F2) |

   The tests make real assertions: exact stdout bytes, empty stdout and credential-free stderr, `Value` equality on the locator, and partial-read checks during startup. None of them only checks that something returned.
5. **Runs.**
   - This Mac:
     - `mix test`: **1,979 passed, 82 excluded** (short `TMPDIR`).
     - `cargo test` in `native/mjolnir_client`: **79 passed**. The `relay_token.rs` file is `#![cfg(target_os = "linux")]`, so none of its tests run on macOS.
     - Focused resolver and protocol run: **60 passed**.
   - Framework laptop: scratch clone at `8d50e04`, own `CARGO_TARGET_DIR` under `/var/tmp`, `nice -n 15`, services and firewall untouched, scratch deleted afterwards.
     - Relay `locator_lifecycle`: **1 passed** as the normal user, plus the ignored test **passed** under `unshare --user --map-root-user`.
     - Client `relay_token`: **5 passed**.
6. **Gates.** No file under `scripts/`, `systemd/` or the `Justfile` changed, and nothing in the diff runs a deploy. The ASK box (`deploy.sh --relay`, which restarts the relay and drains sessions, plus an app deploy, with no `--agent` rebuild) and the EYES box (fresh guest on the Framework's own install) are stated accurately in `tasks.md`.

## Required changes (send-back)

1. F1: harden `Mjolnir.Relay.Locator.read/1` as described: `lstat` regular-file and ≤ 4096-byte check, byte-limited read, and timeout-bounded read in a killable task. Return `%{}` on every refusal.
2. Add the three failing resolver tests (symlink to a valid document, FIFO with a bounded time, 4097-byte file). Record in `tasks.md` that they failed on `8d50e04`.

## Carry to fold

- The EYES box is the only evidence for the `vm.ex` wiring (F2).
- Before production: the owner runs `deploy.sh --relay` (relay restart, drains live sessions) and a normal app deploy. Guests get the fields on their next boot or disk resume.
