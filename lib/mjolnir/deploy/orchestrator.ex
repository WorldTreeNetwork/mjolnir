defmodule Mjolnir.Deploy.Orchestrator do
  @moduledoc """
  End-to-end `mj deploy` orchestration: ties the deploy primitives together.

  Given an app source directory already on the host, `deploy/3` runs the full
  pipeline and returns the app's gateway URL:

      Detector.detect(dir)            # framework + build plan
        → plan_to_steps(plan, dir)    # translate to Builder step-inputs (+ cache keys)
        → Builder.build(...)          # snapshot-layer build in an ephemeral VM
        → Runtime.start(...)          # boot the release as a service VM
        → {:ok, %{url, app_name, release_snapshot, service_vm_id}}

  ## Source ingest (how the source lands in the build)

  The build VM is spawned with the host source directory mounted as an **extra
  virtiofs share** tagged `"src"` (`spawn_opts.extra_mounts`, gge.1.9). The base
  `deploy-node-bun` image does not mount that share automatically, so each build
  step that needs the source **mounts it itself** (idempotently) and copies from
  it into the build workdir (`#{"/app"}`). Ingest is split to preserve the cache
  design (see `Mjolnir.Deploy.Builder.Plan`): the **install** step copies only
  the manifest + lockfiles (its layer is keyed on the lockfile hash, so a source
  edit that leaves the lockfile untouched is still an install cache hit), and the
  **build** step copies the full tree (keyed on the source-tree hash). The
  toolchain step (`mise install`) needs no source and is keyed on the runtime
  spec.

  Because `Mjolnir.Deploy.Builder` execs each step over vsock in a **bare
  (non-login) shell with no persistent cwd**, and because a resumed build boots a
  fresh VM from a cached layer snapshot (which does not carry the runtime virtiofs
  mount), every source-touching step re-establishes the mount and `cd`s into the
  workdir on its own. That is why the step commands are wrapped with a mount
  prelude here rather than assuming any ambient state.

  ## The ops seam (macOS-testable)

  Like `Builder`/`Runtime`, every effect (detect, hashing, build, run, secrets
  lookup) goes through an injectable `ops` map whose defaults capture the real
  modules. Tests pass fakes so the detect → translate → build → run choreography
  — and the exact step-inputs / spawn opts produced — is verified without KVM,
  BTRFS, or a filesystem. What is *not* unit-testable and needs a real server:
  the actual VM boot/exec/snapshot, the virtiofs `src` mount inside the guest,
  and gateway routing.
  """

  require Logger

  alias Mjolnir.Deploy.{Builder, CacheKey, Detector, Diagnostics, Manifest, Runtime}

  @default_base_image "deploy-node-bun"
  @workdir "/app"
  @src_mount "/mnt/deploy-src"
  @default_memory_mb 256

  # Commands Detector emits, used to classify each step's cache-input source.
  @install_commands [
    "npm ci",
    "bun install",
    "pnpm install --frozen-lockfile",
    "yarn install --frozen-lockfile"
  ]
  @lockfiles ~w(package-lock.json bun.lock bun.lockb pnpm-lock.yaml yarn.lock)

  @typedoc "Injectable effect seam; defaults capture the real deploy modules."
  @type ops :: %{
          detect: (String.t() -> {:ok, map()} | {:error, term()}),
          hash_file: (String.t() -> {:ok, String.t()} | {:error, term()}),
          hash_tree: (String.t(), keyword() -> {:ok, String.t()} | {:error, term()}),
          hash_globs: (String.t(), [String.t()] -> {:ok, String.t()} | {:error, term()}),
          build: (String.t(), [map()], keyword() -> {:ok, map()} | {:error, term()}),
          run: (String.t(), String.t(), map(), keyword() -> {:ok, map()} | {:error, term()}),
          read_secrets: (String.t() -> {:ok, map()} | :none | {:error, term()})
        }

  @typedoc "A successful deploy."
  @type result :: %{
          url: String.t(),
          app_name: String.t(),
          release_snapshot: String.t(),
          service_vm_id: String.t()
        }

  @doc """
  Deploys `src_dir` as `app_name` and returns its gateway URL.

  ## Options

    - `:deployer` — owner_id stamped on the build + service VMs.
    - `:memory_mb` — service VM memory. Default `#{@default_memory_mb}`.
    - `:custom_domain` — explicit fqdn to assign on first deploy (preserved
      across redeploys thereafter by `Runtime.start`).
    - `:base_image` — deploy base image / base layer id. Wins over
      `mjolnir.toml` `base_image`. When both are omitted, default
      `#{inspect(@default_base_image)}` (gge.1.10 / mjolnir-6ee1).
    - `:on_progress` — `(stage :: String.t(), line :: String.t() -> any)` invoked
      as each stage advances. Defaults to a no-op. The HTTP endpoint wires this to
      the NDJSON progress stream.
    - `:ops` — effect-seam overrides (map); tests pass fakes.

  Returns `{:ok, result}` (see `t:result/0`) or `{:error, %{stage: String.t(),
  reason: term()}}` naming the stage that failed.
  """
  @spec deploy(String.t(), String.t(), keyword()) ::
          {:ok, result()} | {:error, %{stage: String.t(), reason: term()}}
  def deploy(app_name, src_dir, opts \\ []) when is_binary(app_name) and is_binary(src_dir) do
    ops = Map.merge(default_ops(), Map.new(Keyword.get(opts, :ops, [])))
    progress = Keyword.get(opts, :on_progress, fn _stage, _line -> :ok end)
    deployer = Keyword.get(opts, :deployer)
    memory_mb = Keyword.get(opts, :memory_mb, @default_memory_mb)
    custom_domain = Keyword.get(opts, :custom_domain)

    Logger.info("Deploy.Orchestrator: deploying '#{app_name}' from #{src_dir}")

    with {:detect, {:ok, plan}} <- {:detect, ops.detect.(src_dir)},
         :ok <- emit(progress, "detect", detect_summary(plan)),
         {:translate, {:ok, steps}} <- {:translate, plan_to_steps(plan, src_dir, ops)},
         build_size = build_size(plan),
         :ok <- emit_build_size(progress, build_size),
         :ok <- emit(progress, "build", "#{length(steps)} layer(s); building"),
         base_image = resolve_base_image(opts, plan),
         {:build, {:ok, build}} <-
           {:build,
            tag_build_result(
              ops.build.(
                base_image,
                steps,
                build_opts(base_image, src_dir, deployer, build_size)
              ),
              build_size
            )},
         :ok <-
           emit(
             progress,
             "build",
             "release #{build.release_snapshot} " <>
               "(#{build.cache_hits} hit / #{build.cache_misses} miss)"
           ),
         :ok <- emit_layers(progress, build),
         :ok <- emit(progress, "run", "booting service VM"),
         {:run, {:ok, svc}} <-
           {:run,
            ops.run.(
              app_name,
              build.release_snapshot,
              plan,
              run_opts(app_name, memory_mb, custom_domain, deployer, ops)
            )} do
      emit(progress, "done", svc.url)

      {:ok,
       %{
         url: svc.url,
         app_name: app_name,
         release_snapshot: build.release_snapshot,
         service_vm_id: svc.service_vm_id
       }}
    else
      {:build, {:error, {reason, build_size}}} ->
        Logger.error("Deploy.Orchestrator: '#{app_name}' failed at build: #{inspect(reason)}")
        for line <- failure_lines(reason, build_size), do: emit(progress, "build", line)
        {:error, %{stage: "build", reason: reason}}

      {stage, {:error, reason}} ->
        Logger.error("Deploy.Orchestrator: '#{app_name}' failed at #{stage}: #{inspect(reason)}")
        for line <- failure_lines(reason), do: emit(progress, to_string(stage), line)
        {:error, %{stage: to_string(stage), reason: reason}}
    end
  end

  # Turn a failure into lines a human can act on.
  #
  # `inspect(reason)` on a step failure is a ~1KB tuple containing the whole
  # shell command twice, and it buries the one thing that matters: what the
  # guest kernel said before it died. Lead with the cause, then the guest's own
  # words, then where the full serial log lives.
  defp failure_lines(reason, build_size \\ nil)

  defp failure_lines({:step_failed, command, reason, _built, diag}, build_size) do
    highlights = Map.get(diag, :highlights, [])
    dir = Map.get(diag, :diagnostics_dir)

    [
      "error: build step failed: #{truncate(command, 120)}",
      "cause: #{describe(reason, build_size)}"
    ] ++
      Enum.map(highlights, &"guest: #{truncate(&1, 200)}") ++
      cond do
        dir && highlights == [] ->
          ["note: the guest logged no kernel-level cause; full serial log at #{dir}"]

        dir ->
          ["note: full serial log at #{dir}"]

        true ->
          []
      end
  end

  # Worth naming rather than inspecting: this one is a deliberate refusal, and
  # the operator needs to know it was a refusal and not a crash.
  defp failure_lines({:secrets_unlock_failed, reason}, _build_size) do
    [
      "error: managed secrets never mounted (#{reason})",
      "note: the service was NOT started — /secrets would have been plain rootfs, " <>
        "and the rootfs is captured by snapshots, release layers and @trash",
      "note: fix the unlock (mj doctor <id> shows the failure) and redeploy"
    ]
  end

  defp failure_lines(reason, _build_size), do: ["error: #{inspect(reason)}"]

  # The shapes worth naming. Everything else falls back to inspect/1.
  defp describe({:vsock_unavailable, _}, %{memory_mb: memory_mb}),
    do: Diagnostics.build_agent_loss(memory_mb)

  defp describe({:vsock_unavailable, _}, _build_size),
    do: "the build VM's guest agent stopped responding mid-step (VM died or was killed)"

  defp describe({:exit_code, code, out}, _build_size),
    do: "command exited #{code}: #{truncate(String.trim(to_string(out)), 300)}"

  defp describe(:timeout, _build_size), do: "the step exceeded its timeout"
  defp describe(other, _build_size), do: inspect(other)

  defp truncate(s, max) do
    s = to_string(s)
    if String.length(s) > max, do: String.slice(s, 0, max) <> "…", else: s
  end

  # --- step translation ------------------------------------------------------

  # `--base` / rpc `:base_image` wins; then the manifest pin; then today's
  # Node-specialised default. Do not flip the global default to ubuntu-24.04
  # (mjolnir-6ee1): inferred SvelteKit apps still want bun on PATH.
  defp resolve_base_image(opts, plan) do
    case Keyword.get(opts, :base_image) do
      img when is_binary(img) and img != "" ->
        img

      _ ->
        case plan_base_image(plan) do
          img when is_binary(img) and img != "" -> img
          _ -> @default_base_image
        end
    end
  end

  defp plan_base_image(%{base_image: img}) when is_binary(img) and img != "", do: img
  defp plan_base_image(_), do: nil

  # The one operator-facing line describing what we decided to build. A manifest
  # app has no package_manager (nil) and may declare no runtime, so the inferred
  # phrasing "detected  app ()" would be both ugly and wrong: nothing was
  # detected, the app said so itself. Say which.
  @doc false
  @spec detect_summary(map()) :: String.t()
  def detect_summary(plan) do
    runtime = Map.get(plan, :runtime, "")

    case Map.get(plan, :package_manager) do
      nil when runtime == "" -> "declared app (#{Manifest.filename()})"
      nil -> "declared app (#{Manifest.filename()}, #{runtime})"
      pm -> "detected #{pm} app (#{runtime})"
    end
  end

  @doc """
  Translate a `BuildPlan` into `Mjolnir.Deploy.Builder` step-inputs.

  Each step becomes `%{command, input_hash}` where `input_hash` is computed from
  the right source for its role (runtime spec / lockfile / source tree / table
  step globs) and source-touching commands are wrapped with the appropriate
  virtiofs mount + copy prelude. Exposed for unit testing.
  """
  @spec plan_to_steps(map(), String.t(), ops()) ::
          {:ok, [%{command: String.t(), input_hash: String.t()}]} | {:error, term()}
  def plan_to_steps(plan, src_dir, ops) do
    commands = Map.fetch!(plan, :steps)
    pm = Map.get(plan, :package_manager)
    runtime = Map.get(plan, :runtime, "")

    Enum.reduce_while(commands, {:ok, []}, fn declared_step, {:ok, acc} ->
      case step_input(declared_step, pm, runtime, src_dir, ops) do
        {:ok, step} -> {:cont, {:ok, [step | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp step_input(%{run: command, inputs: globs}, _pm, _runtime, src_dir, ops) do
    hash_globs = Map.get(ops, :hash_globs, &CacheKey.hash_globs/2)

    with {:ok, hash} <- hash_globs.(src_dir, globs),
         {:ok, rel_paths} <- CacheKey.matching_files(src_dir, globs) do
      command = table_prelude(rel_paths) <> " && " <> command
      {:ok, %{command: command, input_hash: hash}}
    end
  end

  defp step_input(command, pm, runtime, src_dir, ops) when is_binary(command) do
    case classify(command) do
      :runtime ->
        {:ok, %{command: command, input_hash: sha_hex(runtime)}}

      :install ->
        with {:ok, hash} <- lockfile_hash(src_dir, pm, ops) do
          {:ok, %{command: manifest_prelude() <> " && " <> command, input_hash: hash}}
        end

      :build ->
        with {:ok, hash} <- ops.hash_tree.(src_dir, []) do
          {:ok, %{command: source_prelude() <> " && " <> command, input_hash: hash}}
        end
    end
  end

  # Classify a plan command by its cache-input source. Unknown commands are
  # treated as source-dependent (the conservative choice: hash the full tree).
  defp classify(command) do
    cond do
      String.starts_with?(command, "mise") -> :runtime
      command in @install_commands -> :install
      true -> :build
    end
  end

  # The install layer is keyed on the lockfile so a source edit that leaves the
  # lockfile untouched stays a cache hit. Fall back to the source-tree hash when
  # no lockfile is present (e.g. a lockfile-less npm project).
  defp lockfile_hash(src_dir, pm, ops) do
    present =
      pm
      |> lockfile_candidates()
      |> Enum.map(&Path.join(src_dir, &1))
      |> Enum.find(&File.exists?/1)

    case present do
      nil -> ops.hash_tree.(src_dir, [])
      path -> ops.hash_file.(path)
    end
  end

  defp lockfile_candidates(:npm), do: ["package-lock.json"]
  defp lockfile_candidates(:bun), do: ["bun.lock", "bun.lockb"]
  defp lockfile_candidates(:pnpm), do: ["pnpm-lock.yaml"]
  defp lockfile_candidates(:yarn), do: ["yarn.lock"]
  defp lockfile_candidates(_), do: []

  # Idempotent virtiofs mount + copy preludes. Each is a self-contained shell
  # snippet (bare, non-login shell) that (1) ensures the workdir + mountpoint
  # exist, (2) mounts the `src` share if not already mounted, (3) `cd`s into the
  # workdir, then (4) copies. Joined to the plan command with ` && `.
  defp mount_prelude do
    "set -e; mkdir -p #{@workdir} #{@src_mount}; " <>
      "mountpoint -q #{@src_mount} || mount -t virtiofs src #{@src_mount}; cd #{@workdir}"
  end

  # Install prelude: copy only the manifest + any lockfiles (keeps the install
  # layer's inputs lockfile-scoped).
  defp manifest_prelude do
    copies =
      Enum.map_join(["package.json" | @lockfiles], "; ", fn f ->
        "cp #{@src_mount}/#{f} #{@workdir}/ 2>/dev/null || true"
      end)

    mount_prelude() <> "; " <> copies
  end

  # Build prelude: copy the full source tree into the workdir.
  defp source_prelude do
    mount_prelude() <> "; cp -a #{@src_mount}/. #{@workdir}/"
  end

  # Table steps copy exactly the host-resolved regular files that participated
  # in hash_globs/2. Expanding on the host avoids depending on guest-shell
  # globstar behavior, and explicit quoted paths preserve nested layout safely.
  defp table_prelude([]), do: "set -e; mkdir -p #{@workdir}; cd #{@workdir}"

  defp table_prelude(rel_paths) do
    copies =
      Enum.map_join(rel_paths, "; ", fn rel_path ->
        source = Path.join(@src_mount, rel_path)
        destination = Path.join(@workdir, rel_path)

        "mkdir -p #{shell_quote(Path.dirname(destination))}; " <>
          "cp #{shell_quote(source)} #{shell_quote(destination)}"
      end)

    mount_prelude() <> "; " <> copies
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp sha_hex(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  # --- build / run option assembly -------------------------------------------

  defp build_opts(base_image, src_dir, deployer, build_size) do
    [
      base_image: base_image,
      spawn_opts: %{
        extra_mounts: [%{tag: "src", shared_dir: src_dir, opts: []}],
        owner_id: deployer,
        vcpus: build_size.vcpus,
        memory_mb: build_size.memory_mb
      }
    ]
  end

  # Build VMs, unlike service VMs, hold a whole dependency graph plus a
  # bundler or compiler run in memory. Before build VMs were sized at all,
  # they inherited :default_memory_mb (512) and died mid-`bun install`,
  # surfacing only as {:vsock_unavailable, ...} with the host showing 29 GB
  # free. Size comes from the manifest's `build` table, else the host's
  # :deploy_build_* defaults, clamped to :deploy_build_max_*.
  defp build_size(plan) do
    requested = Map.get(plan, :build) || %{}
    vcpus = Map.get(requested, :vcpus) || Application.get_env(:mjolnir, :deploy_build_vcpus, 4)

    memory_mb =
      Map.get(requested, :memory_mb) ||
        Application.get_env(:mjolnir, :deploy_build_memory_mb, 4096)

    max_vcpus = Application.get_env(:mjolnir, :deploy_build_max_vcpus, 6)
    max_memory_mb = Application.get_env(:mjolnir, :deploy_build_max_memory_mb, 16_384)

    %{
      vcpus: min(vcpus, max_vcpus),
      memory_mb: min(memory_mb, max_memory_mb),
      requested_vcpus: vcpus,
      requested_memory_mb: memory_mb
    }
  end

  defp emit_build_size(progress, build_size) do
    with :ok <-
           emit(
             progress,
             "build",
             "build VM: #{build_size.vcpus} vCPU, #{build_size.memory_mb} MB"
           ),
         :ok <- emit_clamp(progress, "vcpus", build_size.requested_vcpus, build_size.vcpus),
         :ok <-
           emit_clamp(progress, "memory_mb", build_size.requested_memory_mb, build_size.memory_mb) do
      :ok
    end
  end

  defp emit_clamp(_progress, _key, requested, clamped) when requested == clamped, do: :ok

  defp emit_clamp(progress, key, requested, clamped) do
    emit(progress, "build", "#{key} #{requested} -> #{clamped} (host max)")
  end

  defp tag_build_result({:ok, _} = result, _build_size), do: result
  defp tag_build_result({:error, reason}, build_size), do: {:error, {reason, build_size}}

  defp run_opts(app_name, memory_mb, custom_domain, deployer, ops) do
    spawn_opts =
      %{memory_mb: memory_mb}
      |> Map.merge(secrets_spawn_opts(app_name, ops))
      |> then(fn o -> if deployer, do: Map.put(o, :owner_id, deployer), else: o end)

    # owner_id is recorded on the REGISTRY ENTRY too, not just the service VM:
    # Policy.App authorizes redeploy and domain changes off the entry, which
    # outlives any individual VM (mjolnir-xuv).
    base = [spawn_opts: spawn_opts, owner_id: deployer]

    if is_binary(custom_domain) and custom_domain != "" do
      [{:custom_domain, custom_domain} | base]
    else
      base
    end
  end

  # A per-app secrets file (managed by an operator out of band) enrolls the
  # service VM in :managed (LUKS-escrowed) secrets, injecting the key/values on
  # first boot. Absent → no secrets, plain boot.
  defp secrets_spawn_opts(app_name, ops) do
    case ops.read_secrets.(app_name) do
      {:ok, secrets} when is_map(secrets) and map_size(secrets) > 0 ->
        %{secrets_mode: :managed, secrets: secrets}

      _ ->
        %{}
    end
  end

  # --- default (server-gated) effect seam ------------------------------------

  defp emit(progress, stage, line) do
    progress.(stage, line)
    :ok
  end

  # One progress line per layer, so `mj deploy` shows which layers were
  # reused and, for a miss, its first cause. Builder logs the same lines;
  # Logger output never reaches the deploying client.
  defp emit_layers(progress, %{plan: %{layers: layers}}) when is_list(layers) do
    layers
    |> Enum.with_index(1)
    |> Enum.each(fn
      {%{status: :hit}, index} ->
        emit(progress, "build", "layer #{index}: hit")

      {%{status: :miss, miss_reason: reason}, index} ->
        emit(progress, "build", "layer #{index}: miss (#{reason})")
    end)
  end

  defp emit_layers(_progress, _build), do: :ok

  defp default_ops do
    %{
      detect: &Detector.detect/1,
      hash_file: &CacheKey.hash_file/1,
      hash_tree: &CacheKey.hash_tree/2,
      hash_globs: &CacheKey.hash_globs/2,
      build: &Builder.build/3,
      run: &Runtime.start/4,
      read_secrets: &default_read_secrets/1
    }
  end

  @doc false
  # Read `<deploy_secrets_dir>/<slug>.json` as a flat string map, if present.
  def default_read_secrets(app_name) do
    dir =
      Application.get_env(
        :mjolnir,
        :deploy_secrets_dir,
        "/var/lib/mjolnir/deploy/secrets"
      )

    path = Path.join(dir, slug(app_name) <> ".json")

    with true <- File.exists?(path),
         {:ok, bin} <- File.read(path),
         {:ok, map} <- Jason.decode(bin),
         true <- is_map(map) and Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      {:ok, map}
    else
      false -> :none
      _ -> :none
    end
  end

  defp slug(app_name) do
    app_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "_")
  end
end
