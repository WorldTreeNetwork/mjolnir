defmodule Mjolnir.Deploy.OrchestratorTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Deploy.Orchestrator

  @plan %{
    runtime: "node@20",
    package_manager: :bun,
    steps: ["mise install", "bun install", "bun run build"],
    start_command: "node build/index.js",
    port: 3000
  }

  # A recording ops seam: every effect appends a tagged event so a test can
  # assert on the exact call sequence + the step-inputs / opts produced.
  defp recording_ops(agent, opts) do
    detect_result = Keyword.get(opts, :detect_result, {:ok, @plan})
    build_result = Keyword.get(opts, :build_result, {:ok, build_ok()})
    run_result = Keyword.get(opts, :run_result, {:ok, run_ok()})
    secrets = Keyword.get(opts, :secrets, :none)

    %{
      detect: fn dir ->
        Agent.update(agent, &[{:detect, dir} | &1])
        detect_result
      end,
      hash_file: fn path ->
        Agent.update(agent, &[{:hash_file, path} | &1])
        {:ok, "lockfile-hash"}
      end,
      hash_tree: fn dir, o ->
        Agent.update(agent, &[{:hash_tree, dir, o} | &1])
        {:ok, "tree-hash"}
      end,
      build: fn base, steps, o ->
        Agent.update(agent, &[{:build, base, steps, o} | &1])
        build_result
      end,
      run: fn app, snap, plan, o ->
        Agent.update(agent, &[{:run, app, snap, plan, o} | &1])
        run_result
      end,
      read_secrets: fn app ->
        Agent.update(agent, &[{:read_secrets, app} | &1])
        secrets
      end
    }
  end

  defp build_ok,
    do: %{release_snapshot: "deploy-rel123", cache_hits: 2, cache_misses: 1, built: ["x"]}

  defp run_ok,
    do: %{service_vm_id: "svc-vm-9", url: "https://z-3000.vm.test", app_name: "app"}

  defp events(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()

  setup do
    {:ok, agent} = start_supervised({Agent, fn -> [] end})
    # A real dir with a bun lockfile so the install step exercises hash_file.
    dir = Path.join(System.tmp_dir!(), "orch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "package.json"), "{}")
    File.write!(Path.join(dir, "bun.lock"), "lock")
    on_exit(fn -> File.rm_rf(dir) end)
    %{agent: agent, dir: dir}
  end

  describe "deploy/3 — happy path" do
    test "detect → build → run, returns url + metadata", %{agent: agent, dir: dir} do
      ops = recording_ops(agent, [])

      assert {:ok, r} =
               Orchestrator.deploy("my-app", dir, ops: ops, deployer: "user-1", memory_mb: 512)

      assert r.url == "https://z-3000.vm.test"
      assert r.app_name == "my-app"
      assert r.release_snapshot == "deploy-rel123"
      assert r.service_vm_id == "svc-vm-9"

      ev = events(agent)
      assert {:detect, ^dir} = Enum.find(ev, &match?({:detect, _}, &1))
    end

    test "translates the plan into wrapped Builder step-inputs", %{agent: agent, dir: dir} do
      ops = recording_ops(agent, [])
      assert {:ok, _} = Orchestrator.deploy("my-app", dir, ops: ops, deployer: "user-1")

      {:build, base, steps, o} = Enum.find(events(agent), &match?({:build, _, _, _}, &1))

      assert base == "deploy-node-bun"
      assert o[:base_image] == "deploy-node-bun"
      assert o[:spawn_opts][:owner_id] == "user-1"
      assert [%{tag: "src", shared_dir: ^dir}] = o[:spawn_opts][:extra_mounts]

      [runtime, install, build] = steps

      # Runtime step: command untouched, keyed on the runtime spec hash.
      assert runtime.command == "mise install"
      assert runtime.input_hash == :crypto.hash(:sha256, "node@20") |> Base.encode16(case: :lower)

      # Install step: mounts the share, copies only manifest+lockfiles, then runs
      # the install command; keyed on the lockfile hash (hash_file was used).
      assert install.command =~ "mount -t virtiofs src"
      assert install.command =~ "cp /mnt/deploy-src/package.json"
      assert install.command =~ "bun.lock"
      assert install.command =~ "&& bun install"
      assert install.input_hash == "lockfile-hash"

      # Build step: copies the full tree then builds; keyed on the tree hash.
      assert build.command =~ "cp -a /mnt/deploy-src/. /app/"
      assert build.command =~ "&& bun run build"
      assert build.input_hash == "tree-hash"
    end

    test "runs the release with memory + preserves the plan", %{agent: agent, dir: dir} do
      ops = recording_ops(agent, [])

      assert {:ok, _} =
               Orchestrator.deploy("app", dir,
                 ops: ops,
                 memory_mb: 1024,
                 custom_domain: "app.identikey.io"
               )

      {:run, "app", "deploy-rel123", plan, o} =
        Enum.find(events(agent), &match?({:run, _, _, _, _}, &1))

      assert plan == @plan
      assert o[:spawn_opts][:memory_mb] == 1024
      assert o[:custom_domain] == "app.identikey.io"
      # No secrets file → plain boot.
      refute Map.has_key?(o[:spawn_opts], :secrets_mode)
    end

    test "uses the plan's base_image when set (mjolnir.toml pin)", %{agent: agent, dir: dir} do
      plan = Map.put(@plan, :base_image, "ubuntu-24.04")
      ops = recording_ops(agent, detect_result: {:ok, plan})
      assert {:ok, _} = Orchestrator.deploy("identikey", dir, ops: ops)

      {:build, base, _steps, o} = Enum.find(events(agent), &match?({:build, _, _, _}, &1))
      assert base == "ubuntu-24.04"
      assert o[:base_image] == "ubuntu-24.04"
    end

    test "opts :base_image overrides the plan pin", %{agent: agent, dir: dir} do
      plan = Map.put(@plan, :base_image, "ubuntu-24.04")
      ops = recording_ops(agent, detect_result: {:ok, plan})

      assert {:ok, _} =
               Orchestrator.deploy("identikey", dir, ops: ops, base_image: "arch")

      {:build, base, _, o} = Enum.find(events(agent), &match?({:build, _, _, _}, &1))
      assert base == "arch"
      assert o[:base_image] == "arch"
    end

    test "omitted key still uses deploy-node-bun", %{agent: agent, dir: dir} do
      ops = recording_ops(agent, [])
      assert {:ok, _} = Orchestrator.deploy("app", dir, ops: ops)
      {:build, base, _, _} = Enum.find(events(agent), &match?({:build, _, _, _}, &1))
      assert base == "deploy-node-bun"
    end
  end

  describe "deploy/3 — managed secrets" do
    test "enrolls :managed secrets when a per-app secrets file is present", %{
      agent: agent,
      dir: dir
    } do
      ops = recording_ops(agent, secrets: {:ok, %{"API_KEY" => "shh"}})
      assert {:ok, _} = Orchestrator.deploy("app", dir, ops: ops)

      {:run, _, _, _, o} = Enum.find(events(agent), &match?({:run, _, _, _, _}, &1))
      assert o[:spawn_opts][:secrets_mode] == :managed
      assert o[:spawn_opts][:secrets] == %{"API_KEY" => "shh"}
    end
  end

  describe "deploy/3 — progress + failures" do
    test "emits progress stages in order", %{agent: agent, dir: dir} do
      {:ok, prog} = start_supervised({Agent, fn -> [] end}, id: :prog)
      ops = recording_ops(agent, [])

      on_progress = fn stage, _line -> Agent.update(prog, &[stage | &1]) end
      assert {:ok, _} = Orchestrator.deploy("app", dir, ops: ops, on_progress: on_progress)

      stages = prog |> Agent.get(& &1) |> Enum.reverse()
      assert "detect" in stages
      assert "build" in stages
      assert "run" in stages
      assert List.last(stages) == "done"
    end

    test "surfaces a detect failure with its stage, never building", %{agent: agent, dir: dir} do
      ops = recording_ops(agent, detect_result: {:error, :unsupported_app})

      assert {:error, %{stage: "detect", reason: :unsupported_app}} =
               Orchestrator.deploy("app", dir, ops: ops)

      refute Enum.any?(events(agent), &match?({:build, _, _, _}, &1))
    end

    test "surfaces a build failure with its stage, never running", %{agent: agent, dir: dir} do
      ops = recording_ops(agent, build_result: {:error, {:step_failed, "bun install", :boom, []}})

      assert {:error, %{stage: "build"}} = Orchestrator.deploy("app", dir, ops: ops)
      refute Enum.any?(events(agent), &match?({:run, _, _, _, _}, &1))
    end
  end
end
