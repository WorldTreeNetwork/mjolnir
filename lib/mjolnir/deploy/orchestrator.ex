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

  alias Mjolnir.Deploy.{Builder, CacheKey, Detector, Runtime}

  @default_base_image "deploy-node-bun"
  @workdir "/app"
  @src_mount "/mnt/deploy-src"
  @default_memory_mb 256

  # Build VMs, unlike service VMs, must hold a whole dependency graph plus a
  # bundler run in memory. Overridable via :deploy_build_memory_mb.
  @default_build_memory_mb 2048

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
    - `:base_image` — deploy base image / base layer id. Default
      `#{inspect(@default_base_image)}` (gge.1.10).
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
    base_image = Keyword.get(opts, :base_image, @default_base_image)

    Logger.info("Deploy.Orchestrator: deploying '#{app_name}' from #{src_dir}")

    with {:detect, {:ok, plan}} <- {:detect, ops.detect.(src_dir)},
         :ok <-
           emit(progress, "detect", "detected #{plan.package_manager} app (#{plan.runtime})"),
         {:translate, {:ok, steps}} <- {:translate, plan_to_steps(plan, src_dir, ops)},
         :ok <- emit(progress, "build", "#{length(steps)} layer(s); building"),
         {:build, {:ok, build}} <-
           {:build, ops.build.(base_image, steps, build_opts(base_image, src_dir, deployer))},
         :ok <-
           emit(
             progress,
             "build",
             "release #{build.release_snapshot} " <>
               "(#{build.cache_hits} hit / #{build.cache_misses} miss)"
           ),
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
  defp failure_lines({:step_failed, command, reason, _built, diag}) do
    highlights = Map.get(diag, :highlights, [])
    dir = Map.get(diag, :diagnostics_dir)

    ["error: build step failed: #{truncate(command, 120)}", "cause: #{describe(reason)}"] ++
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
  defp failure_lines({:secrets_unlock_failed, reason}) do
    [
      "error: managed secrets never mounted (#{reason})",
      "note: the service was NOT started — /secrets would have been plain rootfs, " <>
        "and the rootfs is captured by snapshots, release layers and @trash",
      "note: fix the unlock (mj doctor <id> shows the failure) and redeploy"
    ]
  end

  defp failure_lines(reason), do: ["error: #{inspect(reason)}"]

  # The shapes worth naming. Everything else falls back to inspect/1.
  defp describe({:vsock_unavailable, _}),
    do: "the build VM's guest agent stopped responding mid-step (VM died or was killed)"

  defp describe({:exit_code, code, out}),
    do: "command exited #{code}: #{truncate(String.trim(to_string(out)), 300)}"

  defp describe(:timeout), do: "the step exceeded its timeout"
  defp describe(other), do: inspect(other)

  defp truncate(s, max) do
    s = to_string(s)
    if String.length(s) > max, do: String.slice(s, 0, max) <> "…", else: s
  end

  # --- step translation ------------------------------------------------------

  @doc """
  Translate a `BuildPlan` into `Mjolnir.Deploy.Builder` step-inputs.

  Each step becomes `%{command, input_hash}` where `input_hash` is computed from
  the right source for its role (runtime spec / lockfile / source tree) and the
  source-touching commands are wrapped with the virtiofs mount + copy prelude.
  Exposed for unit testing. `ops` supplies `hash_file`/`hash_tree`.
  """
  @spec plan_to_steps(map(), String.t(), ops()) ::
          {:ok, [%{command: String.t(), input_hash: String.t()}]} | {:error, term()}
  def plan_to_steps(plan, src_dir, ops) do
    commands = Map.fetch!(plan, :steps)
    pm = Map.get(plan, :package_manager)
    runtime = Map.get(plan, :runtime, "")

    Enum.reduce_while(commands, {:ok, []}, fn command, {:ok, acc} ->
      case step_input(command, pm, runtime, src_dir, ops) do
        {:ok, step} -> {:cont, {:ok, [step | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp step_input(command, pm, runtime, src_dir, ops) do
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

  defp sha_hex(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  # --- build / run option assembly -------------------------------------------

  defp build_opts(base_image, src_dir, deployer) do
    [
      base_image: base_image,
      spawn_opts: %{
        extra_mounts: [%{tag: "src", shared_dir: src_dir, opts: []}],
        owner_id: deployer,
        # Build VMs are memory-hungry in a way service VMs are not: `bun install`
        # / `npm ci` resolve a whole dependency graph in memory, and a bundler
        # run peaks higher still. Omitting this silently inherited
        # :default_memory_mb (512), sized for small service VMs, and the build VM
        # died mid-`bun install` — surfacing as {:vsock_unavailable, ...} when its
        # agent went away, with the HOST still showing 29GB free.
        memory_mb: build_memory_mb()
      }
    ]
  end

  defp build_memory_mb do
    Application.get_env(:mjolnir, :deploy_build_memory_mb, @default_build_memory_mb)
  end

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

  defp default_ops do
    %{
      detect: &Detector.detect/1,
      hash_file: &CacheKey.hash_file/1,
      hash_tree: &CacheKey.hash_tree/2,
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
