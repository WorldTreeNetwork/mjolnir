defmodule Mjolnir.Deploy.BuilderIntegrationTest do
  @moduledoc """
  Server-gated integration test for the snapshot-layer Builder (mjolnir-gge.1.4).

  Proves the differentiator on real KVM + BTRFS using cheap synthetic marker
  steps (no Node/SvelteKit toolchain — that end-to-end belongs to gge.1.6/1.7):

    1. A cold build boots from the base image, runs every step, and snapshots
       each layer to its content-addressed `deploy-<key>` name.
    2. A no-op re-deploy is a **full cache hit** — no VM is booted at all.
    3. A one-line change to the final step reflink-resumes from the deepest
       cached layer and reruns **only the tail**, and the resulting release
       snapshot still carries the cached layers' files forward.

  Uses the application-configured `default_base_image` and `btrfs_root`, so it
  runs against whatever BTRFS root the node is pointed at. Cleans up every
  `deploy-*` snapshot it creates.
  """
  use Mjolnir.VMCase

  alias Mjolnir.Deploy.Builder
  alias Mjolnir.Deploy.CacheKey

  @moduletag :integration
  @moduletag :snapshot
  @moduletag timeout: 600_000

  @prefix "deploy-"

  defp base_image, do: Application.get_env(:mjolnir, :default_base_image, "ubuntu-24.04")

  # The three marker steps. `tag` flows into the final step's command + input
  # hash so a changed tag simulates a one-line source change to the last layer.
  defp marker_steps(tag) do
    [
      %{command: "echo l1 > /root/l1.txt", input_hash: "itest-l1"},
      %{command: "echo l2 > /root/l2.txt", input_hash: "itest-l2"},
      %{command: "echo #{tag} > /root/l3.txt", input_hash: "itest-l3-#{tag}"}
    ]
  end

  # Recompute the chained layer ids exactly as the planner does, so the test can
  # register snapshot cleanup up-front (before booting anything).
  defp chain_keys(base, steps) do
    {keys, _} =
      Enum.map_reduce(steps, base, fn s, parent ->
        k = CacheKey.compute(parent, s.command, s.input_hash)
        {k, k}
      end)

    keys
  end

  @tag :cloud_hypervisor
  test "caches layers across deploys and reruns only the changed tail" do
    base = base_image()
    v1 = marker_steps("v1")
    v2 = marker_steps("v2")

    # Every layer key that either build can produce — clean them all up, even on
    # failure, regardless of how far the build got.
    all_keys = Enum.uniq(chain_keys(base, v1) ++ chain_keys(base, v2))
    on_exit(fn -> Enum.each(all_keys, &Mjolnir.BTRFS.delete_snapshot(@prefix <> &1)) end)

    # --- 1. Cold build: empty cache, boot from base, build all three layers ---
    assert {:ok, r1} = Builder.build(base, v1)
    assert r1.cache_hits == 0
    assert r1.cache_misses == 3
    assert length(r1.built) == 3
    assert r1.release_snapshot == @prefix <> List.last(chain_keys(base, v1))

    # --- 2. No-op re-deploy: full cache hit, no VM booted ---
    assert {:ok, r2} = Builder.build(base, v1)
    assert r2.cache_hits == 3
    assert r2.cache_misses == 0
    assert r2.built == []
    assert r2.release_snapshot == r1.release_snapshot

    # --- 3. One-line change to the final step: L1/L2 hit, only L3 reruns ---
    assert {:ok, r3} = Builder.build(base, v2)
    assert r3.cache_hits == 2
    assert r3.cache_misses == 1
    assert length(r3.built) == 1
    refute r3.release_snapshot == r1.release_snapshot

    # --- 4. The release boots and carries cached L1/L2 + the fresh L3 ---
    {:ok, vm} = Mjolnir.VM.spawn(%{snapshot: r3.release_snapshot})
    on_exit(fn -> Mjolnir.VM.stop(vm.id) end)

    assert {:ok, o1} = Mjolnir.VM.exec(vm.id, "cat /root/l1.txt")
    assert String.trim(o1) == "l1", "cached L1 file should survive the reflink resume"

    assert {:ok, o2} = Mjolnir.VM.exec(vm.id, "cat /root/l2.txt")
    assert String.trim(o2) == "l2", "cached L2 file should survive the reflink resume"

    assert {:ok, o3} = Mjolnir.VM.exec(vm.id, "cat /root/l3.txt")
    assert String.trim(o3) == "v2", "the reran tail layer should hold the new content"
  end
end
