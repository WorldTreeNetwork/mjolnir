defmodule Mjolnir.Deploy.Runtime do
  @moduledoc """
  Boots a release layer as a long-lived **service VM** and returns its public URL.

  `start/3` takes the release snapshot produced by `Mjolnir.Deploy.Builder` plus
  the app's run spec (`start_command` + `port`, carried on a
  `Mjolnir.Deploy.BuildPlan`) and:

    1. Spawns a service VM from the release snapshot with Iroh enabled — the app
       files are already baked into the snapshot, so nothing is copied.
    2. Waits for the VM's Iroh identity (the z32 ticket) to come up.
    3. Installs an **ad-hoc systemd unit** over vsock with `VM.exec`
       (`Environment=HOST=0.0.0.0 PORT=<port>`, `Restart=on-failure`), then
       `daemon-reload` + `enable --now`. This exec-driven unit is explicitly the
       thing gge.4 replaces with real Forge-over-vsock reconciliation.
    4. Records `{app_name → release snapshot, service vm_id, url}` in
       `Mjolnir.Deploy.Registry` and, on a redeploy, stops the previous service
       VM (cutover).
    5. Returns the gateway HTTPS URL `https://<z32>-<port>.vm.worldtree.network`.

  ## The ops seam (macOS-testable)

  Like `Mjolnir.Deploy.Builder`, all VM/Registry effects go through an injectable
  `ops` map whose defaults capture `Mjolnir.VM` / `Mjolnir.Deploy.Registry`.
  Tests pass fakes so the spawn → await-ticket → install-unit → register
  choreography (and the URL/unit text it produces) is verified without KVM.

  ## P0 scope notes

  - Each deploy boots a **fresh** Iroh identity, so the URL changes per deploy.
    Stable per-app identity (persisted Iroh key) is a later concern.
  - `ExecStart` is wrapped in `/bin/sh -lc` so a login shell picks up the
    mise-activated runtime PATH baked into the layer. Real run-state convergence
    (PATH, users, env files) is deferred to gge.4.
  """

  require Logger

  @default_gateway_domain "vm.worldtree.network"
  @default_workdir "/app"
  @ticket_poll_interval 500

  @typedoc "Injectable effect seam; defaults target Mjolnir.VM / Deploy.Registry."
  @type ops :: %{
          spawn: (map() -> {:ok, map()} | {:error, term()}),
          exec: (String.t(), String.t(), keyword() -> {:ok, String.t()} | {:error, term()}),
          get_ticket: (String.t() -> {:ok, String.t()} | {:error, term()}),
          registry_get: (String.t() -> {:ok, map()} | {:error, term()}),
          registry_put: (String.t(), map() -> {:ok, map()} | {:error, term()}),
          stop: (String.t() -> :ok | {:error, term()})
        }

  @typedoc "A running service."
  @type result :: %{
          app_name: String.t(),
          service_vm_id: String.t(),
          ticket: String.t(),
          url: String.t(),
          release_snapshot: String.t(),
          unit: String.t()
        }

  @doc """
  Boots `release_snapshot` as the service VM for `app_name` and returns its URL.

  `plan` is anything exposing `:start_command` and `:port` (a
  `Mjolnir.Deploy.BuildPlan` or a plain map).

  ## Options

    - `:ops` — effect-seam overrides (map); tests pass fakes.
    - `:workdir` — `WorkingDirectory` for the unit. Default `#{@default_workdir}`.
    - `:gateway_domain` — URL domain. Default from `:mjolnir, :gateway_domain`.
    - `:spawn_opts` — extra spawn options merged into the boot map.
    - `:ticket_timeout` — ms to wait for the Iroh ticket. Default `30_000`.
    - `:custom_domain` — explicitly set the app's custom domain (fqdn) for
      first-time assignment. When omitted, any `custom_domain` already recorded
      for the app is preserved across the redeploy (see `finish/9`); when given,
      it overrides the preserved value.

  Returns `{:ok, result}` (see `t:result/0`) or `{:error, reason}`. On any
  failure after the VM is up, the just-spawned VM is torn down so a failed
  deploy does not strand a VM.
  """
  @spec start(String.t(), String.t(), map(), keyword()) :: {:ok, result()} | {:error, term()}
  def start(app_name, release_snapshot, plan, opts \\ [])
      when is_binary(app_name) and is_binary(release_snapshot) do
    ops = Map.merge(default_ops(), Map.new(Keyword.get(opts, :ops, [])))
    workdir = Keyword.get(opts, :workdir, @default_workdir)
    domain = Keyword.get(opts, :gateway_domain, gateway_domain())
    ticket_timeout = Keyword.get(opts, :ticket_timeout, 30_000)
    spawn_opts = Keyword.get(opts, :spawn_opts, %{})
    custom_domain_opt = Keyword.get(opts, :custom_domain)
    owner_id_opt = Keyword.get(opts, :owner_id)

    port = fetch!(plan, :port)
    start_command = fetch!(plan, :start_command)
    boot = Map.merge(%{snapshot: release_snapshot, enable_iroh: true}, Map.new(spawn_opts))

    unit =
      systemd_unit(app_name, start_command, port, workdir,
        secrets_mode: Map.get(boot, :secrets_mode)
      )

    Logger.info("Deploy.Runtime: starting service '#{app_name}' from #{release_snapshot}")

    case ops.spawn.(boot) do
      {:ok, vm} ->
        vm_id = Map.fetch!(vm, :id)

        case secrets_gate(boot, vm) do
          :ok ->
            finish(
              ops,
              app_name,
              release_snapshot,
              vm_id,
              unit,
              workdir,
              port,
              domain,
              ticket_timeout,
              custom_domain_opt,
              owner_id_opt
            )

          {:error, reason} ->
            # Do not leave a VM running that is one `systemctl start` away from
            # writing plaintext where an encrypted volume was supposed to be.
            _ = ops.stop.(vm_id)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  # Refuse to start an app whose managed secrets never mounted.
  #
  # A :managed deploy hands the VM its secrets expecting them to land in a LUKS
  # volume mounted at /secrets, rendered to tmpfs at /run/mjolnir/secrets.env.
  # If the unlock failed, /secrets is an ORDINARY DIRECTORY ON THE ROOTFS — and
  # the rootfs is snapshotted into @snapshots, into every deploy release layer,
  # and into @trash on delete. Starting the app anyway risks writing plaintext
  # secrets into all of them, and the app would in any case run without the
  # configuration it was given.
  #
  # So: fail the deploy loudly at the one moment someone is watching, rather
  # than hand back a URL for a service that is either broken or leaking. The VM
  # is stopped; the operator fixes the unlock and redeploys.
  #
  # Only applies when this deploy actually asked for :managed secrets. A VM with
  # no secrets has nothing to protect and is unaffected.
  defp secrets_gate(boot, vm) do
    if Map.get(boot, :secrets_mode) == :managed do
      case Map.get(vm, :secrets_unlock_failure) do
        nil ->
          :ok

        %{reason: reason} ->
          Logger.error(
            "Deploy.Runtime: refusing to start service — managed secrets never mounted " <>
              "(#{reason}). /secrets would be plain rootfs; not writing secrets there."
          )

          {:error, {:secrets_unlock_failed, reason}}
      end
    else
      :ok
    end
  end

  defp finish(
         ops,
         app_name,
         release_snapshot,
         vm_id,
         unit,
         workdir,
         port,
         domain,
         ticket_timeout,
         custom_domain_opt,
         owner_id_opt
       ) do
    with {:ok, ticket} <- await_ticket(ops, vm_id, ticket_timeout),
         :ok <- install_unit(ops, vm_id, app_name, unit, workdir) do
      url = gateway_url(ticket, port, domain)

      # Preserve the app's custom_domain across the redeploy. Registry.put builds
      # a FRESH Entry from `attrs`, so any key we omit is wiped — and a wiped
      # custom_domain makes RouteReconciler.desired_specs (which filters on
      # is_binary(custom_domain)) DROP the app's gateway route. An explicit
      # :custom_domain opt (first-time set) overrides the preserved value.
      custom_domain = custom_domain_opt || preserved_custom_domain(ops, app_name)

      # Same preservation rule as custom_domain, for the same reason: Registry.put
      # rebuilds the Entry from attrs, so an omitted owner_id is wiped — and a
      # wiped owner makes Policy.App treat the app as legacy/unowned, locking its
      # real owner out of their own redeploys and domain changes (mjolnir-xuv).
      owner_id = owner_id_opt || preserved_owner_id(ops, app_name)

      # `port` is recorded so the gateway local-route generator
      # (Mjolnir.Gateway.Routes) can build a backend without re-deriving it.
      attrs = %{
        release_snapshot: release_snapshot,
        service_vm_id: vm_id,
        url: url,
        port: port,
        custom_domain: custom_domain,
        owner_id: owner_id
      }

      case ops.registry_put.(app_name, attrs) do
        {:ok, _entry} ->
          cutover_previous(ops, app_name, vm_id)

          # Cutover spawned a new VM (new vm_id → new guest IP), so refresh the
          # gateway's local routes. Debounced + a no-op if the reconciler is off.
          Mjolnir.Gateway.RouteReconciler.trigger()

          {:ok,
           %{
             app_name: app_name,
             service_vm_id: vm_id,
             ticket: ticket,
             url: url,
             release_snapshot: release_snapshot,
             unit: unit
           }}

        {:error, reason} ->
          teardown(ops, vm_id)
          {:error, {:registry_failed, reason}}
      end
    else
      {:error, reason} ->
        # The VM came up (or partway) but a later step failed — don't strand it.
        teardown(ops, vm_id)
        {:error, reason}
    end
  end

  # Read the custom_domain recorded for the app before this redeploy, so it can
  # be carried into the fresh registry entry. Uses the same injectable
  # registry_get seam as cutover. Returns nil when there is no prior entry.
  defp preserved_custom_domain(ops, app_name) do
    case ops.registry_get.(app_name) do
      {:ok, prev} -> Map.get(prev, :custom_domain)
      _ -> nil
    end
  end

  # As above, for the app's owner. An explicit :owner_id opt (first deploy) wins;
  # otherwise the prior entry's owner is carried forward so a redeploy never
  # silently changes who owns the app.
  defp preserved_owner_id(ops, app_name) do
    case ops.registry_get.(app_name) do
      {:ok, prev} -> Map.get(prev, :owner_id)
      _ -> nil
    end
  end

  # Stop the app's previous service VM, if any, now that the new one is registered.
  defp cutover_previous(ops, app_name, new_vm_id) do
    case ops.registry_get.(app_name) do
      {:ok, %{service_vm_id: prev}} when is_binary(prev) and prev != new_vm_id ->
        Logger.info("Deploy.Runtime: cutting over '#{app_name}', stopping previous VM #{prev}")
        _ = ops.stop.(prev)
        :ok

      _ ->
        :ok
    end
  end

  # --- ticket readiness ------------------------------------------------------

  defp await_ticket(ops, vm_id, timeout) do
    deadline = monotonic_ms() + timeout
    do_await_ticket(ops, vm_id, deadline)
  end

  defp do_await_ticket(ops, vm_id, deadline) do
    case ops.get_ticket.(vm_id) do
      {:ok, ticket} when is_binary(ticket) ->
        {:ok, ticket}

      {:error, :not_ready} ->
        if monotonic_ms() >= deadline do
          {:error, :ticket_timeout}
        else
          Process.sleep(@ticket_poll_interval)
          do_await_ticket(ops, vm_id, deadline)
        end

      {:error, reason} ->
        {:error, {:ticket_error, reason}}
    end
  end

  # --- systemd unit installation --------------------------------------------

  defp install_unit(ops, vm_id, app_name, unit, workdir) do
    unit_path = "/etc/systemd/system/#{unit_name(app_name)}"
    # Materialize the WorkingDirectory first: a missing dir is a hard
    # pre-ExecStart CHDIR failure (status=200), not a warning. A quoted heredoc
    # then writes the unit verbatim (no shell expansion of $PORT etc.).
    write_cmd =
      "mkdir -p #{workdir} && cat > #{unit_path} <<'MJOLNIR_UNIT'\n#{unit}\nMJOLNIR_UNIT"

    activate_cmd = "systemctl daemon-reload && systemctl enable --now #{unit_name(app_name)}"

    with {:ok, _} <- ops.exec.(vm_id, write_cmd, []),
         {:ok, _} <- ops.exec.(vm_id, activate_cmd, []) do
      :ok
    else
      {:error, reason} -> {:error, {:unit_install_failed, reason}}
    end
  end

  defp teardown(ops, vm_id) do
    case ops.stop.(vm_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Deploy.Runtime: teardown of #{vm_id} failed: #{inspect(reason)}")
    end
  end

  # --- pure helpers (exported for unit tests) --------------------------------

  @doc """
  Renders the ad-hoc systemd unit for a service.

  `ExecStart` runs the app's `start_command` through `/bin/sh -lc` so a login
  shell resolves the mise-managed runtime baked into the layer.

  Pass `secrets_mode: :managed` to gate the unit on the secrets volume actually
  being mounted — see `secrets_condition/1`.
  """
  @spec systemd_unit(String.t(), String.t(), pos_integer(), String.t(), keyword()) :: String.t()
  def systemd_unit(app_name, start_command, port, workdir \\ @default_workdir, opts \\ []) do
    """
    [Unit]
    Description=Mjolnir deploy: #{app_name}
    After=network-online.target
    Wants=network-online.target
    #{secrets_condition(opts[:secrets_mode])}
    [Service]
    Type=simple
    WorkingDirectory=#{workdir}
    Environment=HOST=0.0.0.0
    Environment=PORT=#{port}
    ExecStart=/bin/sh -lc '#{escape_single_quotes(start_command)}'
    Restart=on-failure
    RestartSec=2

    [Install]
    WantedBy=multi-user.target
    """
  end

  # Refuse to run the service unless /secrets is a REAL mount.
  #
  # `Deploy.Runtime.start/4` already refuses to deploy when the unlock fails at
  # spawn time, but that only covers the deploy. This covers every restart
  # afterwards — a reboot, a resume, `systemctl start`, an operator poking at
  # it. Without it, the first restart after a failed unlock starts the app with
  # /secrets as a plain directory on the rootfs, and the rootfs is captured by
  # @snapshots, by release layers and by @trash.
  #
  # A CONDITION, not a dependency. `RequiresMountsFor=` would be the wrong tool:
  # nothing here creates a systemd .mount unit for /secrets (the guest agent
  # mounts it directly), so systemd would order against a unit that never
  # appears and hang. A failed condition is not a failure either — systemd skips
  # the unit, says so in the journal, and `Restart=on-failure` does not loop.
  #
  # The trade is deliberate: after a failed unlock the service stays down until
  # someone fixes the volume and starts it. Down and explicable beats up and
  # writing plaintext into every future snapshot.
  @doc false
  @spec secrets_condition(atom() | nil) :: String.t()
  def secrets_condition(:managed), do: "ConditionPathIsMountPoint=/secrets\n"
  def secrets_condition(_), do: ""

  @doc """
  Builds the gateway URL `https://<ticket>-<port>.<domain>`.
  """
  @spec gateway_url(String.t(), pos_integer(), String.t()) :: String.t()
  def gateway_url(ticket, port, domain \\ nil) do
    "https://#{ticket}-#{port}.#{domain || gateway_domain()}"
  end

  @doc "The sanitized systemd unit filename for an app (`<slug>.service`)."
  @spec unit_name(String.t()) :: String.t()
  def unit_name(app_name) do
    slug =
      app_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]/, "-")
      |> String.trim("-")

    slug = if slug == "", do: "app", else: slug
    "#{slug}.service"
  end

  # --- internals -------------------------------------------------------------

  # Embed a value inside a single-quoted shell string: close, escaped-quote, reopen.
  defp escape_single_quotes(s), do: String.replace(s, "'", "'\\''")

  defp fetch!(plan, key) when is_map(plan) do
    case Map.fetch(plan, key) do
      {:ok, v} -> v
      :error -> raise ArgumentError, "Deploy.Runtime: plan is missing #{inspect(key)}"
    end
  end

  defp gateway_domain do
    Application.get_env(:mjolnir, :gateway_domain, @default_gateway_domain)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp default_ops do
    %{
      spawn: &Mjolnir.VM.spawn/1,
      exec: &Mjolnir.VM.exec/3,
      get_ticket: &Mjolnir.VM.get_ticket/1,
      registry_get: &Mjolnir.Deploy.Registry.get/1,
      registry_put: &Mjolnir.Deploy.Registry.put/2,
      stop: &Mjolnir.VM.stop/1
    }
  end
end
