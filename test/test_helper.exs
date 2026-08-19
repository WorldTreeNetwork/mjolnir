# Exclude by default:
#   :integration — need KVM + root, run on server only
#   :e2e         — future full-stack tests
#   :chaos       — mutate a live Mjolnir host; opt-in via `mix test --only chaos`
#   :destructive — subset of chaos that cause observable host downtime
#   :postgres    — need postgres + initdb binaries; opt in via --include postgres
#   :recrypt_storage — needs mjolnir-blob-door (Linux host); opt in via
#                      --include recrypt_storage + MJOLNIR_RECRYPT_STORAGE_URL
ExUnit.configure(
  exclude: [
    :integration,
    :e2e,
    :chaos,
    :destructive,
    :requires_ots,
    :postgres,
    :recrypt_storage
  ]
)

# mjolnir-7qh: give each run its own StateStore directory.
#
# `config/test.exs` pointed `:state_dir` at the FIXED path
# /tmp/mjolnir-test/state. The StateStore is process-global and loads that
# directory at application boot — which happens before this file runs — so
# every `mix test` inherited the records left by every previous `mix test`.
# A test that legitimately persists a :running record (managed-secrets boot,
# reconcile) wrote a file that no later run had any reason to remove, and the
# app's own Reconcile then hammered it for minutes, retiring it to :failed.
# Those corpses surfaced in `GET /api/vms` as stranded `recovering` VMs and
# failed unrelated API tests.
#
# This was misdiagnosed as seed-dependent ordering pollution. It is not: the
# failing records were written on a PREVIOUS DAY. Seeds only changed which
# assertions happened to look at the store. Isolating per run removes the
# cross-run channel entirely; a leak within one run is a separate concern and
# the assertions in router_test/mcp server_test no longer depend on it.
state_dir =
  Path.join([
    System.tmp_dir!(),
    "mjolnir-test",
    "state-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  ])

# The legacy shared directory can no longer be in use by anything now that each
# run gets its own. Remove it once so existing checkouts stop carrying years of
# accumulated records forward.
_ = File.rm_rf(Path.join([System.tmp_dir!(), "mjolnir-test", "state"]))

File.mkdir_p!(Path.join(state_dir, "quarantine"))
Application.put_env(:mjolnir, :state_dir, state_dir)
:ok = Mjolnir.StateStore.reload()

System.at_exit(fn _ -> File.rm_rf(state_dir) end)

ExUnit.start()
