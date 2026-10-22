defmodule Mjolnir.Deploy.OrchestratorTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Deploy.Builder.Plan
  alias Mjolnir.Deploy.{CacheKey, Orchestrator}

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

    test "manifest build sizing wins over host defaults and reaches the build spawn opts", %{
      agent: agent,
      dir: dir
    } do
      plan = Map.put(@plan, :build, %{vcpus: 5, memory_mb: 8192})
      ops = recording_ops(agent, detect_result: {:ok, plan})

      assert {:ok, _} = Orchestrator.deploy("app", dir, ops: ops)

      {:build, _, _, opts} = Enum.find(events(agent), &match?({:build, _, _, _}, &1))
      assert opts[:spawn_opts][:vcpus] == 5
      assert opts[:spawn_opts][:memory_mb] == 8192
    end

    test "clamps build sizing, reports it, and leaves service memory alone", %{
      agent: agent,
      dir: dir
    } do
      {:ok, progress} = start_supervised({Agent, fn -> [] end}, id: :progress)
      plan = Map.put(@plan, :build, %{vcpus: 99, memory_mb: 99_999})
      ops = recording_ops(agent, detect_result: {:ok, plan})
      on_progress = fn stage, line -> Agent.update(progress, &[{stage, line} | &1]) end

      assert {:ok, _} =
               Orchestrator.deploy("app", dir,
                 ops: ops,
                 memory_mb: 1024,
                 on_progress: on_progress
               )

      {:build, _, _, build_opts} = Enum.find(events(agent), &match?({:build, _, _, _}, &1))
      {:run, _, _, _, run_opts} = Enum.find(events(agent), &match?({:run, _, _, _, _}, &1))
      assert build_opts[:spawn_opts][:vcpus] == 6
      assert build_opts[:spawn_opts][:memory_mb] == 16_384
      assert run_opts[:spawn_opts][:memory_mb] == 1024

      lines = progress |> Agent.get(& &1) |> Enum.reverse() |> Enum.map(&elem(&1, 1))
      assert "build VM: 6 vCPU, 16384 MB" in lines
      assert "vcpus 99 -> 6 (host max)" in lines
      assert "memory_mb 99999 -> 16384 (host max)" in lines
    end
  end

  describe "plan_to_steps/3 — manifest table inputs" do
    defp filesystem_ops do
      %{
        hash_file: &CacheKey.hash_file/1,
        hash_tree: &CacheKey.hash_tree/2,
        hash_globs: &CacheKey.hash_globs/2
      }
    end

    test "command-only step ignores source edits and mounts no source", %{dir: dir} do
      plan = %{
        @plan
        | runtime: "",
          package_manager: nil,
          steps: [%{run: "apt-get update", inputs: []}]
      }

      assert {:ok, [before]} = Orchestrator.plan_to_steps(plan, dir, filesystem_ops())
      File.write!(Path.join(dir, "unrelated.txt"), "changed")
      assert {:ok, [after_edit]} = Orchestrator.plan_to_steps(plan, dir, filesystem_ops())

      assert before == after_edit
      refute before.command =~ "mount"
      refute before.command =~ "cp "
      assert before.command =~ "cd /app && apt-get update"
      assert before.input_hash == CacheKey.no_inputs_hash()

      cached = CacheKey.compute("base", before.command, before.input_hash)
      assert [%{status: :hit}] = Plan.compute("base", [after_edit], [cached]).layers
    end

    test "glob step changes only for matched files and copies only matches", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "web/nested"))
      File.write!(Path.join(dir, "web/index.js"), "one")
      File.write!(Path.join(dir, "web/nested/view.js"), "two")
      File.write!(Path.join(dir, "server.ex"), "outside")

      plan = %{
        @plan
        | runtime: "",
          package_manager: nil,
          steps: [%{run: "build-web", inputs: ["web/**"]}]
      }

      assert {:ok, [before]} = Orchestrator.plan_to_steps(plan, dir, filesystem_ops())
      assert before.command =~ "--null -T /mnt/deploy-inputs/0.files"
      assert before.input_files == ["web/index.js", "web/nested/view.js"]
      refute before.command =~ "server.ex"

      File.write!(Path.join(dir, "server.ex"), "outside changed")
      assert {:ok, [outside_edit]} = Orchestrator.plan_to_steps(plan, dir, filesystem_ops())
      assert outside_edit == before

      cached = CacheKey.compute("base", before.command, before.input_hash)
      assert [%{status: :hit}] = Plan.compute("base", [outside_edit], [cached]).layers

      File.write!(Path.join(dir, "web/index.js"), "matched changed")
      assert {:ok, [matched_edit]} = Orchestrator.plan_to_steps(plan, dir, filesystem_ops())
      assert matched_edit.command == before.command
      assert matched_edit.input_hash != before.input_hash

      assert [%{status: :miss, miss_reason: :inputs}] =
               Plan.compute("base", [matched_edit], [cached]).layers
    end

    test "5,000-file glob uses a bounded command and copies only matches", %{
      agent: agent,
      dir: dir
    } do
      File.mkdir_p!(Path.join(dir, "web"))
      paths = for index <- 1..5000, do: "web/file-#{index}.txt"
      paths = paths ++ ["web/with space\nand newline.txt"]
      for path <- paths, do: File.write!(Path.join(dir, path), path)
      File.write!(Path.join(dir, "excluded.txt"), "excluded")

      plan = %{
        @plan
        | runtime: "",
          package_manager: nil,
          steps: [%{run: "true", inputs: ["web/**"]}]
      }

      ops = recording_ops(agent, detect_result: {:ok, plan})
      destination = Path.join(dir, "copied")
      File.mkdir_p!(destination)

      ops =
        Map.put(ops, :build, fn _, [step], opts ->
          assert byte_size(step.command) < 65_536
          share = Enum.find(opts[:spawn_opts][:extra_mounts], &(&1.tag == "inputs"))
          refute String.starts_with?(share.shared_dir, dir <> "/")
          list = File.read!(Path.join(share.shared_dir, step.input_list))
          assert String.split(list, <<0>>, trim: true) == Enum.sort(paths)
          Agent.update(agent, &[{:input_share, share.shared_dir} | &1])
          # Run the actual archive/copy part locally; mounting virtiofs is server-only.
          [_, copy] = String.split(step.command, "; tar -C ", parts: 2)

          command =
            ("tar -C " <> copy)
            |> String.replace("/mnt/deploy-src", "'#{dir}'")
            |> String.replace("/mnt/deploy-inputs", "'#{share.shared_dir}'")
            |> String.replace("/app", "'#{destination}'")
            |> String.replace("/tmp/deploy-0.files.tar", "'#{destination}/copy.tar'")

          assert {_, 0} = System.cmd("sh", ["-c", command], stderr_to_stdout: true)
          assert {:ok, copied} = CacheKey.matching_files(destination, ["**"])
          assert copied == Enum.sort(paths)
          {:ok, build_ok()}
        end)

      assert {:ok, _} = Orchestrator.deploy("app", dir, ops: ops)
      {:input_share, share_dir} = Enum.find(events(agent), &match?({:input_share, _}, &1))
      refute File.exists?(share_dir)
    end

    test "empty glob matches keep a stable command and clean up lists on build failure", %{
      agent: agent,
      dir: dir
    } do
      plan = %{
        @plan
        | runtime: "",
          package_manager: nil,
          steps: [%{run: "true", inputs: ["web/**"]}]
      }

      assert {:ok, [empty]} = Orchestrator.plan_to_steps(plan, dir, filesystem_ops())
      ops = recording_ops(agent, detect_result: {:ok, plan})

      ops =
        Map.put(ops, :build, fn _, [step], opts ->
          share = Enum.find(opts[:spawn_opts][:extra_mounts], &(&1.tag == "inputs"))
          assert File.read!(Path.join(share.shared_dir, step.input_list)) == ""
          Agent.update(agent, &[{:input_share, share.shared_dir} | &1])
          {:error, :build_failed}
        end)

      assert {:error, %{stage: "build", reason: :build_failed}} =
               Orchestrator.deploy("app", dir, ops: ops)

      {:input_share, share_dir} = Enum.find(events(agent), &match?({:input_share, _}, &1))
      refute File.exists?(share_dir)

      File.mkdir_p!(Path.join(dir, "web"))
      File.write!(Path.join(dir, "web/first.txt"), "first")
      assert {:ok, [populated]} = Orchestrator.plan_to_steps(plan, dir, filesystem_ops())
      assert empty.command == populated.command
      assert empty.input_hash != populated.input_hash
    end

    test "string step keeps full-tree hash and copy behavior", %{dir: dir} do
      plan = %{@plan | runtime: "", package_manager: nil, steps: ["make"]}
      assert {:ok, [before]} = Orchestrator.plan_to_steps(plan, dir, filesystem_ops())

      File.write!(Path.join(dir, "any-file"), "changed")
      assert {:ok, [after_edit]} = Orchestrator.plan_to_steps(plan, dir, filesystem_ops())

      assert before.command =~ "cp -a /mnt/deploy-src/. /app/"
      assert before.input_hash != after_edit.input_hash

      cached = CacheKey.compute("base", before.command, before.input_hash)

      assert [%{status: :miss, miss_reason: :inputs}] =
               Plan.compute("base", [after_edit], [cached]).layers
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

    test "reports every layer's hit or miss cause to the deploying client", %{
      agent: agent,
      dir: dir
    } do
      {:ok, prog} = start_supervised({Agent, fn -> [] end}, id: :layer_prog)

      layers = [
        %{status: :hit, miss_reason: nil},
        %{status: :miss, miss_reason: :inputs},
        %{status: :miss, miss_reason: :parent}
      ]

      build = Map.put(build_ok(), :plan, %{layers: layers})
      ops = recording_ops(agent, build_result: {:ok, build})
      on_progress = fn stage, line -> Agent.update(prog, &[{stage, line} | &1]) end
      assert {:ok, _} = Orchestrator.deploy("app", dir, ops: ops, on_progress: on_progress)

      lines = prog |> Agent.get(& &1) |> Enum.reverse() |> Enum.map(&elem(&1, 1))
      assert "layer 1: hit" in lines
      assert "layer 2: miss (inputs)" in lines
      assert "layer 3: miss (parent)" in lines
    end

    test "surfaces a detect failure with its stage, never building", %{agent: agent, dir: dir} do
      ops = recording_ops(agent, detect_result: {:error, :unsupported_app})

      assert {:error, %{stage: "detect", reason: :unsupported_app}} =
               Orchestrator.deploy("app", dir, ops: ops)

      refute Enum.any?(events(agent), &match?({:build, _, _, _}, &1))
    end

    test "names a vsock miss and the base image", %{agent: agent, dir: dir} do
      {:ok, progress} = start_supervised({Agent, fn -> [] end}, id: :agent_miss)
      ops = recording_ops(agent, build_result: {:error, {:spawn_failed, :boot_timeout}})
      on_progress = fn stage, line -> Agent.update(progress, &[{stage, line} | &1]) end

      assert {:error, %{stage: "build", reason: {:spawn_failed, :boot_timeout}}} =
               Orchestrator.deploy("app", dir, ops: ops, on_progress: on_progress)

      lines = progress |> Agent.get(& &1) |> Enum.reverse() |> Enum.map(&elem(&1, 1))
      assert "base image deploy-node-bun" in lines
      assert "error: guest agent never pinged on vsock (boot_timeout)" in lines
    end

    test "surfaces a build failure with its stage, never running", %{agent: agent, dir: dir} do
      ops = recording_ops(agent, build_result: {:error, {:step_failed, "bun install", :boom, []}})

      assert {:error, %{stage: "build"}} = Orchestrator.deploy("app", dir, ops: ops)
      refute Enum.any?(events(agent), &match?({:run, _, _, _, _}, &1))
    end

    test "names build memory when its agent disappears", %{agent: agent, dir: dir} do
      {:ok, progress} = start_supervised({Agent, fn -> [] end}, id: :progress)
      plan = Map.put(@plan, :build, %{memory_mb: 8192, vcpus: 4})

      ops =
        recording_ops(agent,
          detect_result: {:ok, plan},
          build_result:
            {:error, {:step_failed, "cargo build", {:vsock_unavailable, :closed}, [], %{}}}
        )

      on_progress = fn stage, line -> Agent.update(progress, &[{stage, line} | &1]) end

      assert {:error, %{stage: "build"}} =
               Orchestrator.deploy("app", dir, ops: ops, on_progress: on_progress)

      lines = progress |> Agent.get(& &1) |> Enum.reverse() |> Enum.map(&elem(&1, 1))
      assert "cause: build VM stopped responding; it had 8192 MB. Raise build.memory_mb." in lines
    end
  end
end
