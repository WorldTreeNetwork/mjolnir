defmodule Mjolnir.API.Router do
  @moduledoc """
  HTTP API router for Mjolnir VM management.

  Provides RESTful endpoints for spawning, listing, inspecting,
  executing commands in, and stopping microVMs. Authentication is
  handled by `Mjolnir.API.Auth` (JWT or localhost bypass).

  ## Deploy API contract (v0)

  The `mj deploy` client lane consumes exactly this shape — keep it stable.

  ### `POST /api/deploy`

  Deploys an app from a source tree and streams progress.

    * **Body**: a **gzipped tar** of the app source. The tar may wrap the source
      in a single top-level directory or contain it at the root — both work
      (the server locates the dir holding `package.json`).
    * **Headers**:
      * `X-App-Name` — the app's stable name. Fallback: derived from the tar's
        single top-level directory, else `"app"`.
      * `X-Memory-MB` — service VM memory. Default `256`.
      * `X-Domain` — optional custom-domain fqdn to assign on first deploy.
    * **Response**: `200` with `Content-Type: application/x-ndjson`, a stream of
      newline-delimited JSON objects. Progress lines are `{"stage": ..., "line":
      ...}` (stages: `detect`, `build`, `run`, `done`, or a failing stage name).
      The **final** line is the result object:
      * success — `{"ok": true, "url": ..., "app_name": ..., "release_snapshot":
        ..., "service_vm_id": ...}`
      * failure — `{"ok": false, "error": ..., "stage": ...}`
    * A malformed/empty/undecompressable body is rejected with a plain `400`
      JSON error *before* the stream starts.

  ### `PUT /api/apps/:app/domain`

    * **Body**: `{"fqdn": "zine.identikey.io"}`.
    * **Response**: `200` `{"app", "fqdn", "backend", "apex_registered": true,
      "cert_present": bool}`. `404` if the app is not deployed; `400`
      `{"error": "apex_not_registered", ...}` if the fqdn's apex is not in
      `:gateway_apexes`.

  ### `DELETE /api/apps/:app/domain`

    * **Response**: `200` `{"app", "removed": true}`; `404` if not deployed.

  ### `PUT /api/apps/:app`

    * **Body**: `{"service_vm_id": "<uuid>", "port": 3000}` and optional
      `release_snapshot`, `force`. Binds an **existing** running VM as a
      named app. Does not spawn or stop a VM. Marks the entry `stateful`
      so a later `mj deploy` refuses cutover unless `force`.
    * **Response**: `200` `{app, service_vm_id, port, release_snapshot,
      stateful}`. `404` `vm_not_found`. `409` `app_exists` or
      `stateful_vm_mismatch`.

  ### `GET /api/apps`

    * **Response**: `200` `{"apps": [{"app_name", "url", "custom_domain",
      "service_vm_id", "backend", "port", "apex_registered", "cert_present",
      "http01_ready"}]}` (`backend` is `"<ip>:<port>"` when the service VM is
      running/local, else `null`). `apex_registered` / `cert_present` /
      `http01_ready` are `true`/`false` when `custom_domain` is set and `null`
      when there is no `custom_domain`. `apex_registered` is whether the
      fqdn's apex is currently in `:gateway_apexes` (`false` means the
      gateway route is silently dropped, mjolnir-1pk).

  ### `PUT /api/apps/:app/secrets`

    * **Body**: `{"key": "STRIPE_API_KEY", "value": "sk_live_…"}` or
      `{"entries": {"STRIPE_API_KEY": "sk_live_…"}}`. Merges into the
      existing deploy-secrets JSON. Never replace the whole file.
    * **Response**: `200` `{"app", "slug", "set": ["STRIPE_API_KEY"],
      "keys": […]}`. Values are never returned. `404` if the app is not
      deployed (or the caller does not own it).

  ### `GET /api/apps/:app/secrets`

    * **Response**: `200` `{"app", "slug", "keys": ["DATABASE_URL", …]}`.
      Names only.

  ### `DELETE /api/apps/:app/secrets/:key`

    * **Response**: `200` `{"app", "slug", "unset", "keys"}`. `404`
      `secret_not_found` if that key is absent.

  ### `POST /api/certs/issue`

    * **Body**: `{"fqdn": "taskmaster.dev"}`. Wildcards (`*.`) are refused
      (`400 wildcard_not_supported`). HTTP-01 only — the name must already
      reach this gateway.
    * **Response**: `200` `{"fqdn", "status", "not_after"}`. Never returns
      PEMs. `404` if no app owns that custom domain (or the caller does not
      own the app). `400` if `fqdn` is missing or a wildcard.

  ### `GET /api/certs`

    * **Response**: `200` `{"certs": [{"host", "not_after", "issuer", "sans"}]}`.
      Localhost sees every `[[cert]]`; a regular user sees only certs for
      apps they own. Never returns PEMs.
  """

  use Plug.Router

  import Mjolnir.API.Authz
  alias Mjolnir.API.{Validation, Views}

  require Logger

  plug(Plug.Logger)
  plug(:maybe_parse_body)
  plug(Mjolnir.API.Auth)
  plug(Mjolnir.API.VanityHostPlug)
  plug(:match)
  plug(:dispatch)

  # IdentiKey Sites — raw-binary endpoints for publishing/serving signed
  # snapshots. The body parser is bypassed for this prefix in
  # `maybe_parse_body/2` so envelopes/ciphertext/outboards arrive intact.
  forward("/api/sites", to: Mjolnir.API.SitesRouter)

  # Health check — no auth required (skipped by Auth plug)
  get "/api/health" do
    json(conn, 200, %{status: "ok"})
  end

  # IdentiKey Connect login (device-code, same client as `mj login`).
  get "/auth/login" do
    next = Mjolnir.Auth.Login.safe_next(conn.query_params["next"])

    case Mjolnir.Auth.Login.begin(next) do
      {:ok, started} ->
        conn
        |> put_resp_content_type("text/html; charset=utf-8")
        |> send_resp(200, Mjolnir.API.LoginPage.render(started))

      {:error, reason} ->
        Logger.error("IdentiKey login failed to start: #{inspect(reason)}")

        json(conn, 502, %{
          error: "identikey_unavailable",
          message: "IdentiKey Connect did not start a login"
        })
    end
  end

  get "/auth/wait/:id" do
    case Mjolnir.Auth.Login.poll(id) do
      {:ok, token, next} ->
        conn
        |> put_resp_cookie(Mjolnir.API.Auth.term_cookie(), token,
          http_only: true,
          secure: true,
          same_site: "Lax",
          path: "/",
          max_age: 12 * 60 * 60
        )
        |> json(200, %{ok: true, next: next})

      :pending ->
        json(conn, 200, %{ok: false, pending: true})

      {:error, reason} ->
        json(conn, 200, %{ok: false, error: to_string(reason)})
    end
  end

  get "/auth/logout" do
    conn
    |> delete_resp_cookie(Mjolnir.API.Auth.term_cookie(), path: "/")
    |> put_resp_header("location", "/auth/login")
    |> send_resp(302, "")
  end

  # Hosted browser terminal (mjolnir-wrug). Same origin as the PTY socket
  # so the `mj_term` cookie can authenticate the WebSocket upgrade — a
  # browser cannot set Authorization on `new WebSocket(...)`.
  get "/term/:id" do
    conn = require_scope(conn, "pty:connect")

    unless conn.halted do
      case Validation.validate_vm_id(id) do
        {:ok, vm_id} ->
          conn = Mjolnir.API.TermPage.stash_token(conn)

          unless conn.halted do
            case pty_session_param(conn.query_params["session"]) do
              {:ok, session} ->
                html = Mjolnir.API.TermPage.render(vm_id, session || "main")

                conn
                |> put_resp_content_type("text/html; charset=utf-8")
                |> send_resp(200, html)

              {:error, message} ->
                json(conn, 400, %{error: "invalid_session", message: message})
            end
          else
            conn
          end

        {:error, message} ->
          json(conn, 400, %{error: "invalid_vm_id", message: message})
      end
    else
      conn
    end
  end

  # Spawn a new VM
  post "/api/vms" do
    conn = require_scope(conn, "vms:spawn")

    unless conn.halted do
      opts = %{}

      # Validate base_image if provided (path traversal prevention)
      opts =
        case conn.body_params["base_image"] do
          nil ->
            opts

          base_image ->
            case Validation.validate_safe_name(base_image, "base_image") do
              {:ok, name} -> Map.put(opts, :base_image, name)
              {:error, msg} -> Map.put(opts, :_validation_error, msg)
            end
        end

      opts =
        case conn.body_params["memory_mb"] do
          nil -> opts
          val -> Map.put(opts, :memory_mb, Validation.validate_integer(val, 512, 128, 32_768))
        end

      opts =
        case conn.body_params["vcpus"] do
          nil -> opts
          val -> Map.put(opts, :vcpus, Validation.validate_integer(val, 1, 1, 64))
        end

      opts =
        if conn.body_params["ssh_public_key"],
          do: Map.put(opts, :ssh_public_key, conn.body_params["ssh_public_key"]),
          else: opts

      opts =
        case conn.body_params["snapshot"] do
          nil ->
            opts

          snapshot ->
            case Validation.validate_safe_name(snapshot, "snapshot") do
              {:ok, name} -> Map.put(opts, :snapshot, name)
              {:error, msg} -> Map.put(opts, :_validation_error, msg)
            end
        end

      opts =
        if conn.body_params["preserve_iroh_key"],
          do: Map.put(opts, :preserve_iroh_key, conn.body_params["preserve_iroh_key"]),
          else: opts

      opts =
        if Map.has_key?(conn.body_params, "enable_iroh"),
          do: Map.put(opts, :enable_iroh, conn.body_params["enable_iroh"]),
          else: opts

      # Opaque orchestrator labels. Bounded because they are persisted on every
      # record and returned on every list; an unbounded map here would be a cheap
      # way to bloat the state directory.
      opts =
        case conn.body_params["metadata"] do
          nil ->
            opts

          metadata ->
            case Validation.validate_metadata(metadata) do
              {:ok, normalized} -> Map.put(opts, :metadata, normalized)
              {:error, msg} -> Map.put(opts, :_validation_error, msg)
            end
        end

      opts =
        case conn.body_params["secrets_mode"] do
          "managed" ->
            Map.put(opts, :secrets_mode, :managed)

          "persistent" ->
            Map.put(opts, :secrets_mode, :persistent)

          "ephemeral" ->
            Map.put(opts, :secrets_mode, :ephemeral)

          "none" ->
            Map.put(opts, :secrets_mode, :none)

          nil ->
            opts

          _ ->
            Map.put(
              opts,
              :_validation_error,
              "secrets_mode must be 'managed', 'persistent', 'ephemeral', or 'none'"
            )
        end

      # Lifetime policy (mjolnir-yhr). "never" stops Mjolnir.Reconcile from
      # rehydrating this VM if it later ends up stranded — required by callers
      # whose guest may legitimately end itself and must stay ended (Buzz I5).
      # Unrecognised values are rejected rather than defaulted: a caller that
      # asked for "Never" and silently got "always" would believe it had a
      # guarantee it does not have.
      opts =
        case conn.body_params["restart_policy"] do
          nil ->
            opts

          "always" ->
            Map.put(opts, :restart_policy, :always)

          "never" ->
            Map.put(opts, :restart_policy, :never)

          _ ->
            Map.put(opts, :_validation_error, "restart_policy must be 'always' or 'never'")
        end

      opts =
        case conn.body_params["extra_mounts"] do
          nil ->
            opts

          mounts when is_list(mounts) ->
            parsed =
              Enum.reduce_while(mounts, {:ok, []}, fn mount, {:ok, acc} ->
                with tag when is_binary(tag) and tag != "" <- Map.get(mount, "tag"),
                     path when is_binary(path) and path != "" <- Map.get(mount, "path"),
                     {:ok, safe_tag} <- Validation.validate_safe_name(tag, "extra_mounts tag"),
                     {:ok, safe_path} <- validate_mount_path(path) do
                  entry = %{
                    tag: safe_tag,
                    shared_dir: safe_path,
                    opts: []
                  }

                  {:cont, {:ok, [entry | acc]}}
                else
                  _ ->
                    {:halt,
                     {:error, "extra_mounts entries must have string 'tag' and 'path' fields"}}
                end
              end)

            case parsed do
              {:ok, entries} -> Map.put(opts, :extra_mounts, Enum.reverse(entries))
              {:error, msg} -> Map.put(opts, :_validation_error, msg)
            end

          _ ->
            Map.put(opts, :_validation_error, "extra_mounts must be an array")
        end

      # Buzz agent identity (nsec + relay). Stored in SecretStore, never on the
      # VM record. Independent of secrets_mode — this is not LUKS material.
      opts =
        case Mjolnir.Identity.parse_params(conn.body_params["identity"]) do
          :absent ->
            opts

          {:ok, identity} ->
            Map.put(opts, :identity, identity)

          {:error, msg} ->
            Map.put(opts, :_validation_error, msg)
        end

      # Optional secret material delivered into the LUKS volume on first boot
      # (managed mode only). Held transiently; ends up encrypted in the volume.
      opts =
        case conn.body_params["secrets"] do
          nil ->
            opts

          secrets when is_map(secrets) and map_size(secrets) > 0 ->
            cond do
              opts[:secrets_mode] != :managed ->
                Map.put(
                  opts,
                  :_validation_error,
                  "secrets may only be provided with secrets_mode 'managed'"
                )

              not Enum.all?(secrets, fn {k, v} -> is_binary(k) and is_binary(v) end) ->
                Map.put(
                  opts,
                  :_validation_error,
                  "secrets must be a flat object of string keys to string values"
                )

              true ->
                Map.put(opts, :secrets, secrets)
            end

          secrets when is_map(secrets) ->
            # empty object — nothing to inject
            opts

          _ ->
            Map.put(opts, :_validation_error, "secrets must be a JSON object")
        end

      # Short-circuit on any validation error (base_image, snapshot, etc.)
      if opts[:_validation_error] do
        json(conn, 400, %{error: opts[:_validation_error]})
      else
        # Stamp ownership from authenticated user
        opts = Map.put(opts, :owner_id, conn.assigns[:user_id])
        # Remove sentinel key before passing to VM.spawn
        opts = Map.delete(opts, :_validation_error)

        try do
          case spawn_rejecting_memory_snapshot(opts) do
            {:error, {:memory_snapshot_requires_thaw, name}} ->
              json(conn, 400, %{
                error: "memory_snapshot_requires_thaw",
                snapshot: name,
                hint: "mj thaw #{name}"
              })

            {:ok, vm} ->
              json(conn, 201, Views.render_vm(vm))

            {:error, reason} ->
              Logger.error("VM spawn failed: #{inspect(reason)}")
              json(conn, 500, %{error: "spawn_failed"})
          end
        catch
          :exit, reason ->
            Logger.error("VM spawn crashed: #{inspect(reason)}")
            json(conn, 500, %{error: "spawn_failed"})
        end
      end
    else
      conn
    end
  end

  # List all VMs
  get "/api/vms" do
    conn = require_scope(conn, "vms:read")

    unless conn.halted do
      user_id = conn.assigns[:user_id]

      # ?metadata.<key>=<value>, repeatable. Every pair must match, so a caller
      # can narrow with a cheap selector and then verify with an exact one —
      # a truncated selector is collision-resistant, not collision-free.
      selector = metadata_selector(conn.query_params)

      vms =
        Mjolnir.VM.list()
        |> Enum.filter(fn vm ->
          (user_id == "localhost" or vm.owner_id == user_id) and
            metadata_matches?(vm.metadata, selector)
        end)
        |> Enum.map(&Views.render_vm_summary/1)

      # Stranded VMs: crashed GenServers with a surviving :running record,
      # awaiting Reconcile. Shown as state=recovering so they never look "gone".
      stranded =
        Mjolnir.VM.list_stranded()
        |> Enum.filter(fn record ->
          (user_id == "localhost" or
             Map.get(record.spawn_config || %{}, "owner_id") == user_id) and
            metadata_matches?(record.metadata, selector)
        end)
        |> Enum.map(&Views.render_stranded_summary/1)

      # Failed VMs: records Reconcile retired after repeated resume failures
      # (mjolnir-5fu). Shown as state=failed — preserved + revivable, not gone.
      failed =
        Mjolnir.VM.list_failed()
        |> Enum.filter(fn record ->
          (user_id == "localhost" or
             Map.get(record.spawn_config || %{}, "owner_id") == user_id) and
            metadata_matches?(record.metadata, selector)
        end)
        |> Enum.map(&Views.render_failed_summary/1)

      # Stopped VMs: records Reconcile finalized because restart_policy=never
      # (mjolnir-yhr). Not gone — the rootfs is preserved for a later
      # owner-initiated start — so they are listed rather than silently dropped.
      stopped =
        Mjolnir.VM.list_stopped()
        |> Enum.filter(fn record ->
          (user_id == "localhost" or
             Map.get(record.spawn_config || %{}, "owner_id") == user_id) and
            metadata_matches?(record.metadata, selector)
        end)
        |> Enum.map(&Views.render_stopped_summary/1)

      json(conn, 200, %{vms: vms ++ stranded ++ failed ++ stopped})
    else
      conn
    end
  end

  # Storage overview: whole-disk usage + per-area CoW-aware sizes
  get "/api/storage" do
    conn = require_scope(conn, "vms:read")

    unless conn.halted do
      json(conn, 200, Mjolnir.Storage.overview())
    else
      conn
    end
  end

  # List soft-deleted VMs awaiting GC, with restore eligibility + reap countdown
  get "/api/trash" do
    conn = require_scope(conn, "vms:read")

    unless conn.halted do
      user_id = conn.assigns[:user_id]

      case Mjolnir.Storage.list_trash() do
        {:ok, entries} ->
          visible =
            Enum.filter(entries, fn e ->
              owner = get_in(e, [:metadata, "spawn_config", "owner_id"])
              user_id == "localhost" or owner == user_id or is_nil(owner)
            end)

          json(conn, 200, %{trash: Enum.map(visible, &Views.render_trash_entry/1)})

        {:error, reason} ->
          json(conn, 500, %{error: "trash_list_failed", reason: inspect(reason)})
      end
    else
      conn
    end
  end

  # Restore a soft-deleted VM from trash (undo a kill within the retention window)
  post "/api/trash/:id/restore" do
    conn = require_scope(conn, "vms:spawn")

    unless conn.halted do
      user_id = conn.assigns[:user_id]

      case Mjolnir.BTRFS.find_trashed(id) do
        {:ok, entry} ->
          owner = get_in(entry, [:metadata, "spawn_config", "owner_id"])

          # Ownership: a user may only restore their own VM. Localhost (the
          # SSH-tunnel admin path) and ownerless legacy entries are allowed.
          if user_id == "localhost" or owner == user_id or is_nil(owner) do
            restore_from_trash(conn, id)
          else
            json(conn, 403, %{error: "forbidden"})
          end

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_in_trash"})
      end
    else
      conn
    end
  end

  # WebSocket PTY endpoint (must be before /api/vms/:id to avoid being captured)
  #
  # `?session=<name>` attaches the PTY to a shared tmux session in the guest instead
  # of spawning a private shell. Two sockets naming the same session drive one
  # terminal — that is how multiple humans, or a human and the in-VM agent (which
  # reaches the same session via the terminal_* API), end up collaborating.
  # Omitting the param preserves the original private-shell behaviour.
  get "/api/vms/:id/pty" do
    conn = require_scope(conn, "pty:connect")

    unless conn.halted do
      # nil means "no shared session", which is distinct from validate_session_name/2's
      # nil case — that one defaults to "dev" and would silently opt every existing
      # caller into a shared terminal.
      case pty_session_param(conn.query_params["session"]) do
        {:ok, session} ->
          authorize_vm(conn, id, :pty, fn _vm ->
            Mjolnir.API.PtyHandler.call(conn, id, session)
          end)

        {:error, message} ->
          json(conn, 400, %{error: "invalid_session", message: message})
      end
    else
      conn
    end
  end

  defp pty_session_param(nil), do: {:ok, nil}
  defp pty_session_param(""), do: {:ok, nil}
  defp pty_session_param(name), do: Validation.validate_session_name(name, "session")

  # Get VM details
  get "/api/vms/:id" do
    conn = require_scope(conn, "vms:read")

    unless conn.halted do
      authorize_vm(conn, id, :read, fn vm ->
        _ = Mjolnir.CILease.renew(id)
        json(conn, 200, Views.render_vm(vm))
      end)
    else
      conn
    end
  end

  # VM health report (per-VM probe & heal)
  get "/api/vms/:id/health" do
    conn = require_scope(conn, "vms:read")

    unless conn.halted do
      authorize_vm(conn, id, :read, fn _vm ->
        _ = Mjolnir.CILease.renew(id)

        case Mjolnir.Health.check(id) do
          {:ok, report} -> json(conn, 200, encode_health_report(report))
          {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
        end
      end)
    else
      conn
    end
  end

  # Trigger probe-and-heal up to max_level (default 2)
  post "/api/vms/:id/heal" do
    conn = require_scope(conn, "vms:exec")

    unless conn.halted do
      authorize_vm(conn, id, :exec, fn _vm ->
        max_level = Map.get(conn.body_params || %{}, "max_level", 2)

        case Mjolnir.Health.heal(id, max_level: max_level) do
          {:ok, report} -> json(conn, 200, encode_health_report(report))
          {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
        end
      end)
    else
      conn
    end
  end

  # L5 escape hatch: destroy VM state and respawn with same UUID.
  # Scoped under :stop because it's destructive of in-VM state.
  post "/api/vms/:id/nuke" do
    conn = require_scope(conn, "vms:stop")

    unless conn.halted do
      authorize_vm(conn, id, :stop, fn _vm ->
        case Mjolnir.Health.nuke(id) do
          :ok -> json(conn, 200, %{ok: true})
          {:error, reason} -> json(conn, 500, %{error: "nuke_failed", reason: inspect(reason)})
        end
      end)
    else
      conn
    end
  end

  # Retire a stranded :running record to :failed so Reconcile stops resuming it
  # (mjolnir-5fu). Operates on a record with no live GenServer; rootfs preserved.
  post "/api/vms/:id/retire" do
    conn = require_scope(conn, "vms:stop")

    unless conn.halted do
      authorize_record(conn, id, fn ->
        case Mjolnir.VM.retire(id) do
          :ok ->
            json(conn, 200, %{ok: true, id: id, state: "failed"})

          {:error, :running} ->
            json(conn, 409, %{error: "vm_running", reason: "kill the live VM before retiring"})

          {:error, :not_found} ->
            json(conn, 404, %{error: "not_found"})
        end
      end)
    else
      conn
    end
  end

  # Revive a record back to :running. For a crashed/:failed record this clears
  # the failure counter so the next Reconcile pass boots it; for a live-but-
  # wedged VM it reboots the guest in place and re-attaches (mjolnir-l4i).
  post "/api/vms/:id/revive" do
    conn = require_scope(conn, "vms:spawn")

    unless conn.halted do
      authorize_record(conn, id, fn ->
        case Mjolnir.VM.revive(id) do
          :ok ->
            json(conn, 200, %{ok: true, id: id, state: "running"})

          {:error, :not_found} ->
            json(conn, 404, %{error: "not_found"})

          {:error, reason} ->
            json(conn, 502, %{error: "revive_failed", reason: inspect(reason)})
        end
      end)
    else
      conn
    end
  end

  # Restart a VM (kill hypervisor → resume from preserved rootfs). Recovery for
  # a guest wedged while the hypervisor still reports Running — e.g. after a
  # snapshot pause/resume (mjolnir-l4i). Does NOT use CH's in-place vm.reboot,
  # which cannot reconnect Mjolnir's external virtiofsd backend.
  post "/api/vms/:id/reboot" do
    conn = require_scope(conn, "vms:spawn")

    unless conn.halted do
      authorize_record(conn, id, fn ->
        case Mjolnir.VM.reboot(id) do
          {:ok, %{guest_healthy: true} = result} ->
            json(conn, 200, Map.merge(%{ok: true, id: id}, result))

          {:ok, result} ->
            json(
              conn,
              502,
              Map.merge(%{ok: false, id: id, error: "guest_unhealthy_after_reboot"}, result)
            )

          {:error, :not_found} ->
            json(conn, 404, %{error: "not_found"})

          {:error, reason} ->
            json(conn, 502, %{error: "reboot_failed", reason: inspect(reason)})
        end
      end)
    else
      conn
    end
  end

  # Permanently dispose of a stranded/:failed record: soft-delete its rootfs to
  # @trash (recoverable) and remove the StateStore record (mjolnir-5fu).
  post "/api/vms/:id/forget" do
    conn = require_scope(conn, "vms:stop")

    unless conn.halted do
      authorize_record(conn, id, fn ->
        case Mjolnir.VM.forget(id) do
          :ok ->
            json(conn, 200, %{ok: true, id: id})

          {:error, :running} ->
            json(conn, 409, %{error: "vm_running", reason: "stop the live VM before forgetting"})

          {:error, :not_found} ->
            json(conn, 404, %{error: "not_found"})

          {:error, reason} ->
            json(conn, 500, %{error: "forget_failed", reason: inspect(reason)})
        end
      end)
    else
      conn
    end
  end

  # Host-wide health report (KVM, vsock module, IP forwarding, btrfs mount, ...)
  get "/api/health/host" do
    conn = require_scope(conn, "vms:read")

    unless conn.halted do
      entries = Mjolnir.Health.check_host()
      overall = Mjolnir.Health.Host |> host_overall(entries)
      json(conn, 200, %{overall: overall, checks: Enum.map(entries, &encode_host_entry/1)})
    else
      conn
    end
  end

  # Trigger host-wide heal (sysctl, NAT rule, dirs, ...). Idempotent.
  post "/api/health/host/heal" do
    conn = require_scope(conn, "vms:exec")

    unless conn.halted do
      :ok = Mjolnir.Health.heal_host()
      entries = Mjolnir.Health.check_host()
      overall = host_overall(Mjolnir.Health.Host, entries)
      json(conn, 200, %{overall: overall, checks: Enum.map(entries, &encode_host_entry/1)})
    else
      conn
    end
  end

  # Execute command in VM
  post "/api/vms/:id/exec" do
    conn = require_scope(conn, "vms:exec")

    unless conn.halted do
      authorize_vm(conn, id, :exec, fn _vm ->
        # Renew this VM's CI lease (mjolnir-urp) — a no-op for anything not
        # tagged metadata["purpose"]="ci". exec is the mandatory renewal
        # point: it's the only traffic guaranteed during a long-running job
        # (a cold cargo build is one exec with no other API calls in between).
        _ = Mjolnir.CILease.renew(id)

        with {:ok, command} <- Validation.validate_command(conn.body_params["command"]) do
          case Mjolnir.VM.exec(id, command, timeout: :infinity) do
            {:ok, output} ->
              json(conn, 200, %{output: output})

            {:error, {:exit_code, code, stderr}} ->
              json(conn, 200, %{exit_code: code, stderr: stderr})

            {:error, :not_found} ->
              json(conn, 404, %{error: "not_found"})

            {:error, reason} ->
              Logger.error("VM exec failed for #{id}: #{inspect(reason)}")
              json(conn, 500, %{error: "exec_failed"})
          end
        else
          {:error, msg} -> json(conn, 400, %{error: msg})
        end
      end)
    else
      conn
    end
  end

  # Terminal endpoints

  # List terminal sessions
  get "/api/vms/:id/terminal" do
    conn = require_scope(conn, "terminal:read")

    unless conn.halted do
      authorize_vm(conn, id, :exec, fn _vm ->
        case Mjolnir.VM.terminal_list(id) do
          {:ok, response} ->
            sessions = Map.get(response, "sessions", [])
            json(conn, 200, %{sessions: sessions})

          {:error, :not_found} ->
            json(conn, 404, %{error: "not_found"})

          {:error, reason} ->
            Logger.error("Terminal list failed for #{id}: #{inspect(reason)}")
            json(conn, 500, %{error: "terminal_list_failed"})
        end
      end)
    else
      conn
    end
  end

  # Open or ensure a terminal session
  post "/api/vms/:id/terminal/open" do
    conn = require_scope(conn, "terminal:write")

    unless conn.halted do
      authorize_vm(conn, id, :exec, fn _vm ->
        case Validation.validate_session_name(conn.body_params["session_name"], "session_name") do
          {:ok, session_name} ->
            case Mjolnir.VM.terminal_open(id, session_name) do
              {:ok, response} ->
                json(conn, 200, %{
                  session_name: Map.get(response, "session_name", session_name),
                  status: Map.get(response, "status", "opened")
                })

              {:error, :not_found} ->
                json(conn, 404, %{error: "not_found"})

              {:error, reason} ->
                Logger.error("Terminal open failed for #{id}: #{inspect(reason)}")
                json(conn, 500, %{error: "terminal_open_failed"})
            end

          {:error, msg} ->
            json(conn, 400, %{error: msg})
        end
      end)
    else
      conn
    end
  end

  # Read terminal content
  get "/api/vms/:id/terminal/:session_name" do
    conn = require_scope(conn, "terminal:read")

    unless conn.halted do
      authorize_vm(conn, id, :exec, fn _vm ->
        case Validation.validate_session_name(session_name, "session_name") do
          {:ok, validated_name} ->
            scrollback_lines =
              Validation.validate_scrollback_lines(conn.query_params["scrollback_lines"])

            case Mjolnir.VM.terminal_read(id, validated_name, scrollback_lines) do
              {:ok, response} ->
                json(conn, 200, %{
                  content: Map.get(response, "content", ""),
                  pane_rows: Map.get(response, "pane_rows"),
                  pane_cols: Map.get(response, "pane_cols"),
                  running_command: Map.get(response, "running_command")
                })

              {:error, :not_found} ->
                json(conn, 404, %{error: "not_found"})

              {:error, reason} ->
                Logger.error("Terminal read failed for #{id}: #{inspect(reason)}")
                json(conn, 500, %{error: "terminal_read_failed"})
            end

          {:error, msg} ->
            json(conn, 400, %{error: msg})
        end
      end)
    else
      conn
    end
  end

  # Send command or keys to terminal
  post "/api/vms/:id/terminal/:session_name/send" do
    conn = require_scope(conn, "terminal:write")

    unless conn.halted do
      authorize_vm(conn, id, :exec, fn _vm ->
        case Validation.validate_session_name(session_name, "session_name") do
          {:ok, validated_name} ->
            command = conn.body_params["command"]
            keys = conn.body_params["keys"]

            # Validate command if provided (keys are intentionally unvalidated — they are tmux key names)
            cmd_valid = if command, do: Validation.validate_command(command), else: {:ok, nil}

            case cmd_valid do
              {:ok, _} ->
                case Mjolnir.VM.terminal_send(id, validated_name, command, keys) do
                  {:ok, _response} ->
                    json(conn, 200, %{sent: true})

                  {:error, :not_found} ->
                    json(conn, 404, %{error: "not_found"})

                  {:error, reason} ->
                    Logger.error("Terminal send failed for #{id}: #{inspect(reason)}")
                    json(conn, 500, %{error: "terminal_send_failed"})
                end

              {:error, msg} ->
                json(conn, 400, %{error: msg})
            end

          {:error, msg} ->
            json(conn, 400, %{error: msg})
        end
      end)
    else
      conn
    end
  end

  # Send command and wait for output
  post "/api/vms/:id/terminal/:session_name/send-and-read" do
    conn = require_scope(conn, "terminal:write")

    unless conn.halted do
      authorize_vm(conn, id, :exec, fn _vm ->
        with {:ok, validated_name} <-
               Validation.validate_session_name(session_name, "session_name"),
             {:ok, command} <- Validation.validate_command(conn.body_params["command"]) do
          timeout_ms =
            Validation.validate_timeout(conn.body_params["timeout_ms"], 30_000, 300_000)

          try do
            case Mjolnir.VM.terminal_send_and_read(id, validated_name, command, timeout_ms) do
              {:ok, response} ->
                json(conn, 200, %{
                  output: Map.get(response, "output", ""),
                  exit_code: Map.get(response, "exit_code"),
                  duration_ms: Map.get(response, "duration_ms"),
                  timed_out: Map.get(response, "timed_out", false)
                })

              {:error, :not_found} ->
                json(conn, 404, %{error: "not_found"})

              {:error, reason} ->
                Logger.error("Terminal send_and_read failed for #{id}: #{inspect(reason)}")
                json(conn, 500, %{error: "terminal_send_and_read_failed"})
            end
          catch
            :exit, {:timeout, _} ->
              json(conn, 504, %{error: "timeout"})
          end
        else
          {:error, msg} -> json(conn, 400, %{error: msg})
        end
      end)
    else
      conn
    end
  end

  # Close a terminal session
  delete "/api/vms/:id/terminal/:session_name" do
    conn = require_scope(conn, "terminal:write")

    unless conn.halted do
      authorize_vm(conn, id, :exec, fn _vm ->
        case Validation.validate_session_name(session_name, "session_name") do
          {:ok, validated_name} ->
            case Mjolnir.VM.terminal_close(id, validated_name) do
              {:ok, _response} ->
                json(conn, 200, %{session_name: validated_name, closed: true})

              {:error, :not_found} ->
                json(conn, 404, %{error: "not_found"})

              {:error, reason} ->
                Logger.error("Terminal close failed for #{id}: #{inspect(reason)}")
                json(conn, 500, %{error: "terminal_close_failed"})
            end

          {:error, msg} ->
            json(conn, 400, %{error: msg})
        end
      end)
    else
      conn
    end
  end

  # Send message to a VM (inter-VM messaging / coroutine wake-up)
  post "/api/vms/:id/messages" do
    conn = require_scope(conn, "vms:exec")

    unless conn.halted do
      authorize_vm(conn, id, :message, fn _vm ->
        from_vm_id = conn.body_params["from_vm_id"] || "external"
        payload = conn.body_params["payload"] || %{}
        # Plug stringifies atoms; missing id must stay nil so Mailbox generates one.

        # Validate from_vm_id ownership when not "external"
        authorized =
          if from_vm_id == "external" do
            true
          else
            user = %{user_id: conn.assigns[:user_id]}

            case Mjolnir.VM.get(from_vm_id) do
              {:ok, from_vm} -> Mjolnir.Policy.VM.authorize(:message, user, from_vm) == :ok
              # Not found or unreachable (mjolnir-8ie): cannot authorize the sender.
              {:error, _} -> false
            end
          end

        if authorized do
          message_id = conn.body_params["id"]

          case Mjolnir.VM.deliver_message(id, from_vm_id, payload, id: message_id) do
            {:ok, %{message_id: mid, status: status}} ->
              json(conn, 200, %{ok: true, message_id: mid, status: status})

            {:error, :not_found} ->
              json(conn, 404, %{error: "not_found"})

            {:error, :admission_denied} ->
              json(conn, 403, %{error: "admission_denied"})

            {:error, :invalid_message_id} ->
              json(conn, 400, %{error: "invalid_message_id"})

            {:error, reason} ->
              Logger.error("Message delivery failed for #{id}: #{inspect(reason)}")
              json(conn, 500, %{error: "message_delivery_failed"})
          end
        else
          json(conn, 404, %{error: "not_found"})
        end
      end)
    else
      conn
    end
  end

  # Stop VM
  delete "/api/vms/:id" do
    conn = require_scope(conn, "vms:stop")

    unless conn.halted do
      authorize_vm(conn, id, :stop, fn _vm ->
        # Optional compare-and-delete fence. A caller that observed the VM at
        # generation N can prove nothing has changed since; without the header
        # the delete is unconditional, exactly as before.
        case check_if_match(conn, id) do
          :ok ->
            case Mjolnir.VM.stop(id) do
              :ok ->
                json(conn, 200, %{ok: true})

              {:error, :not_found} ->
                json(conn, 404, %{error: "not_found"})

              {:error, reason} ->
                Logger.error("VM stop failed for #{id}: #{inspect(reason)}")
                json(conn, 500, %{error: "stop_failed"})
            end

          {:error, :conflict, current} ->
            json(conn, 409, %{
              error: "generation_conflict",
              expected: current,
              message:
                "VM #{id} is at generation #{current}; the delete was fenced to a different one. " <>
                  "Re-read the VM and decide again."
            })

          {:error, :malformed} ->
            json(conn, 400, %{error: "If-Match must be a positive integer generation"})
        end
      end)
    else
      conn
    end
  end

  # Get connection ticket (compact z32 + full iroh JSON for interop)
  get "/api/vms/:id/ticket" do
    conn = require_scope(conn, "pty:connect")

    unless conn.halted do
      authorize_vm(conn, id, :ticket, fn _vm ->
        case Mjolnir.VM.connection_info(id) do
          {:ok, ticket, iroh_addr} ->
            json(conn, 200, %{ticket: ticket, iroh_addr: iroh_addr})

          {:error, :not_ready} ->
            json(conn, 503, %{error: "not_ready"})

          {:error, :not_found} ->
            json(conn, 404, %{error: "not_found"})
        end
      end)
    else
      conn
    end
  end

  # Await PTY readiness, returns compact ticket
  post "/api/vms/:id/await-pty" do
    conn = require_scope(conn, "pty:connect")

    unless conn.halted do
      authorize_vm(conn, id, :pty, fn _vm ->
        timeout = Validation.validate_timeout(conn.body_params["timeout"], 30_000, 300_000)

        case Mjolnir.VM.await_pty(id, timeout) do
          {:ok, ticket} ->
            json(conn, 200, %{ticket: ticket})

          {:error, :timeout} ->
            json(conn, 504, %{error: "timeout"})

          {:error, :not_found} ->
            json(conn, 404, %{error: "not_found"})
        end
      end)
    else
      conn
    end
  end

  # Authorize an Iroh peer for secret injection
  post "/api/vms/:id/authorize-inject" do
    conn = require_scope(conn, "vms:exec")

    unless conn.halted do
      authorize_vm(conn, id, :exec, fn _vm ->
        case conn.body_params["peer_node_id"] do
          nil ->
            json(conn, 400, %{error: "peer_node_id is required"})

          peer_node_id when is_binary(peer_node_id) ->
            case Mjolnir.VM.authorize_inject_peer(id, peer_node_id) do
              :ok ->
                json(conn, 200, %{ok: true, authorized: peer_node_id})

              {:error, :not_found} ->
                json(conn, 404, %{error: "not_found"})

              {:error, reason} ->
                Logger.error("Authorize inject failed for #{id}: #{inspect(reason)}")
                json(conn, 500, %{error: "authorize_inject_failed"})
            end

          _ ->
            json(conn, 400, %{error: "peer_node_id must be a string"})
        end
      end)
    else
      conn
    end
  end

  # Create snapshot of a VM
  post "/api/vms/:id/snapshots" do
    conn = require_scope(conn, "snapshots:create")

    unless conn.halted do
      case Validation.validate_safe_name(conn.body_params["name"], "name") do
        {:ok, name} ->
          authorize_vm(conn, id, :snapshot, fn vm ->
            case Mjolnir.VM.snapshot(id, name, owner_id: vm.owner_id) do
              {:ok, metadata} ->
                json(conn, 201, Mjolnir.MemorySnapshot.annotate(metadata))

              {:error, {:snapshot_exists, _}} ->
                json(conn, 409, %{error: "name unavailable"})

              {:error, :not_found} ->
                json(conn, 404, %{error: "vm not_found"})

              # The snapshot artifact exists, but the live guest was left wedged
              # by the pause/resume and could not be auto-recovered (mjolnir-l4i).
              # Fail loudly so callers don't treat the VM as healthy, but hand
              # back the snapshot metadata and a recovery hint.
              {:error, {:guest_unreachable_after_snapshot, reason, metadata}} ->
                Logger.error(
                  "Snapshot #{name} created for #{id} but guest is wedged: #{inspect(reason)}"
                )

                json(conn, 502, %{
                  error: "guest_unreachable_after_snapshot",
                  reason: inspect(reason),
                  snapshot: metadata,
                  hint:
                    "snapshot created, but the live guest did not recover; try `mj reboot #{id}`"
                })

              {:error, reason} ->
                Logger.error("Snapshot create failed for #{id}: #{inspect(reason)}")
                json(conn, 500, %{error: "snapshot_failed"})
            end
          end)

        {:error, msg} ->
          json(conn, 400, %{error: msg})
      end
    else
      conn
    end
  end

  # Park a running VM (memory snapshot). The source VMM is torn down.
  post "/api/vms/:id/freeze" do
    conn = require_scope(conn, "snapshots:create")

    unless conn.halted do
      case Validation.validate_safe_name(conn.body_params["name"], "name") do
        {:ok, name} ->
          authorize_vm(conn, id, :snapshot, fn vm ->
            case Mjolnir.VM.freeze(id, name, owner_id: vm.owner_id) do
              {:ok, metadata} ->
                json(conn, 201, Map.put(metadata, :parked, true))

              {:error, {:snapshot_exists, _}} ->
                json(conn, 409, %{error: "name unavailable"})

              {:error, :not_found} ->
                json(conn, 404, %{error: "vm not_found"})

              {:error, {:not_running, state}} ->
                json(conn, 409, %{error: "not_running", state: state})

              {:error, {:secrets_quiesce_required, mode}} ->
                json(conn, 409, %{error: "secrets_quiesce_required", secrets_mode: mode})

              {:error, reason} ->
                Logger.error("Freeze failed for #{id}: #{inspect(reason)}")
                json(conn, 500, %{error: "freeze_failed"})
            end
          end)

        {:error, msg} ->
          json(conn, 400, %{error: msg})
      end
    else
      conn
    end
  end

  # List all snapshots
  get "/api/snapshots" do
    conn = require_scope(conn, "snapshots:read")

    unless conn.halted do
      case Mjolnir.BTRFS.list_snapshots() do
        {:ok, snapshots} ->
          user_id = conn.assigns[:user_id]

          filtered =
            snapshots
            |> Enum.filter(fn meta ->
              user_id == "localhost" or meta[:owner_id] == user_id
            end)
            |> Enum.map(&Mjolnir.MemorySnapshot.annotate/1)

          json(conn, 200, %{snapshots: filtered})

        {:error, reason} ->
          Logger.error("Snapshot list failed: #{inspect(reason)}")
          json(conn, 500, %{error: "snapshot_list_failed"})
      end
    else
      conn
    end
  end

  # Get snapshot metadata
  get "/api/snapshots/:name" do
    conn = require_scope(conn, "snapshots:read")

    unless conn.halted do
      case Validation.validate_safe_name(name, "snapshot name") do
        {:ok, validated_name} ->
          case Mjolnir.BTRFS.get_snapshot(validated_name) do
            {:ok, %{metadata: metadata}} ->
              user = %{user_id: conn.assigns[:user_id]}

              case Mjolnir.Policy.Snapshot.authorize(:read, user, metadata) do
                :ok -> json(conn, 200, Mjolnir.MemorySnapshot.annotate(metadata))
                :error -> json(conn, 404, %{error: "not_found"})
              end

            {:error, {:snapshot_not_found, _}} ->
              json(conn, 404, %{error: "not_found"})

            {:error, reason} ->
              Logger.error("Snapshot get failed for '#{validated_name}': #{inspect(reason)}")
              json(conn, 500, %{error: "snapshot_get_failed"})
          end

        {:error, msg} ->
          json(conn, 400, %{error: msg})
      end
    else
      conn
    end
  end

  # Restore a parked VM from a memory snapshot (same VM id).
  post "/api/snapshots/:name/thaw" do
    conn = require_scope(conn, "vms:spawn")

    unless conn.halted do
      case Validation.validate_safe_name(name, "snapshot name") do
        {:ok, validated_name} ->
          case Mjolnir.BTRFS.get_snapshot(validated_name) do
            {:ok, %{metadata: metadata}} ->
              user = %{user_id: conn.assigns[:user_id]}

              case Mjolnir.Policy.Snapshot.authorize(:thaw, user, metadata) do
                :ok ->
                  case Mjolnir.VM.thaw(validated_name, owner_id: metadata[:owner_id]) do
                    {:ok, vm} ->
                      json(conn, 201, Views.render_vm(vm))

                    {:error, :not_a_memory_snapshot} ->
                      json(conn, 400, %{
                        error: "not_a_memory_snapshot",
                        hint: "mj spawn --snapshot #{validated_name}"
                      })

                    {:error, {:vm_running, vm_id, _}} ->
                      json(conn, 409, %{error: "vm_running", vm_id: vm_id})

                    {:error, {:snapshot_not_found, _}} ->
                      json(conn, 404, %{error: "not_found"})

                    {:error, reason} ->
                      Logger.error("Thaw failed for '#{validated_name}': #{inspect(reason)}")

                      json(conn, 500, %{error: "thaw_failed"})
                  end

                :error ->
                  json(conn, 404, %{error: "not_found"})
              end

            {:error, {:snapshot_not_found, _}} ->
              json(conn, 404, %{error: "not_found"})

            {:error, reason} ->
              Logger.error("Snapshot lookup failed for '#{validated_name}': #{inspect(reason)}")
              json(conn, 500, %{error: "snapshot_lookup_failed"})
          end

        {:error, msg} ->
          json(conn, 400, %{error: msg})
      end
    else
      conn
    end
  end

  # List dormant VMs
  get "/api/dormant" do
    conn = require_scope(conn, "vms:read")

    unless conn.halted do
      user_id = conn.assigns[:user_id]

      dormant =
        Mjolnir.DormantRegistry.list()
        |> Enum.filter(fn entry ->
          user_id == "localhost" or entry.owner_id == user_id
        end)
        |> Enum.map(fn entry ->
          %{
            vm_id: entry.vm_id,
            snapshot_name: entry.snapshot_name,
            owner_id: entry.owner_id,
            dormant_since: DateTime.to_iso8601(entry.dormant_since),
            pending_messages: length(entry.pending_messages),
            state: entry.state
          }
        end)

      json(conn, 200, %{dormant: dormant})
    else
      conn
    end
  end

  # Delete a snapshot
  delete "/api/snapshots/:name" do
    conn = require_scope(conn, "snapshots:delete")

    unless conn.halted do
      case Validation.validate_safe_name(name, "snapshot name") do
        {:ok, validated_name} ->
          case Mjolnir.BTRFS.get_snapshot(validated_name) do
            {:ok, %{metadata: metadata}} ->
              user = %{user_id: conn.assigns[:user_id]}

              case Mjolnir.Policy.Snapshot.authorize(:delete, user, metadata) do
                :ok ->
                  case Mjolnir.BTRFS.delete_snapshot(validated_name) do
                    :ok ->
                      json(conn, 200, %{ok: true})

                    {:error, {:snapshot_not_found, _}} ->
                      json(conn, 404, %{error: "not_found"})

                    {:error, reason} ->
                      Logger.error(
                        "Snapshot delete failed for '#{validated_name}': #{inspect(reason)}"
                      )

                      json(conn, 500, %{error: "snapshot_delete_failed"})
                  end

                :error ->
                  json(conn, 404, %{error: "not_found"})
              end

            {:error, {:snapshot_not_found, _}} ->
              json(conn, 404, %{error: "not_found"})

            {:error, reason} ->
              Logger.error("Snapshot lookup failed for '#{validated_name}': #{inspect(reason)}")
              json(conn, 500, %{error: "snapshot_lookup_failed"})
          end

        {:error, msg} ->
          json(conn, 400, %{error: msg})
      end
    else
      conn
    end
  end

  # Deploy an app from a gzipped-tar source body; stream NDJSON progress.
  # See the module doc for the full request/response contract.
  post "/api/deploy" do
    conn = require_scope(conn, "vms:spawn")

    # Ownership is checked inside handle_deploy: the app name is only known
    # after the uploaded source is extracted (resolve_app_name reads
    # package.json), so authorize_deploy runs there rather than here.
    if conn.halted, do: conn, else: handle_deploy(conn)
  end

  # Adopt an existing running VM as a named app without cutover.
  put "/api/apps/:app" do
    conn = require_scope(conn, "vms:spawn")

    unless conn.halted do
      handle_adopt(conn, app)
    else
      conn
    end
  end

  # Set (or change) an app's custom domain.
  put "/api/apps/:app/domain" do
    conn = require_scope(conn, "vms:spawn")

    unless conn.halted do
      # mjolnir-xuv: retargeting a domain is the highest-leverage action on this
      # surface — it aims a hostname at a VM — so it requires ownership of the
      # app, not merely a token with the right scope.
      authorize_app(conn, app, :set_domain, fn _entry ->
        case conn.body_params["fqdn"] do
          fqdn when is_binary(fqdn) and fqdn != "" ->
            case Mjolnir.API.Domains.set_domain(app, fqdn) do
              {:ok, result} ->
                json(conn, 200, result)

              {:error, :not_found} ->
                json(conn, 404, %{error: "app_not_found", app: app})

              {:error, {:apex_not_registered, bad_fqdn, apexes}} ->
                json(conn, 400, %{
                  error: "apex_not_registered",
                  fqdn: bad_fqdn,
                  detail:
                    "no configured gateway apex matches '#{bad_fqdn}'; " <>
                      "add it to MJOLNIR_GATEWAY_APEXES (configured: #{Enum.join(apexes, ", ")})"
                })

              {:error, {:registry_failed, reason}} ->
                Logger.error("Domain set failed for #{app}: #{inspect(reason)}")
                json(conn, 500, %{error: "domain_set_failed"})
            end

          _ ->
            json(conn, 400, %{error: "fqdn is required"})
        end
      end)
    else
      conn
    end
  end

  # Clear an app's custom domain.
  delete "/api/apps/:app/domain" do
    conn = require_scope(conn, "vms:spawn")

    unless conn.halted do
      authorize_app(conn, app, :remove_domain, fn _entry ->
        case Mjolnir.API.Domains.remove_domain(app) do
          {:ok, result} ->
            json(conn, 200, result)

          {:error, :not_found} ->
            json(conn, 404, %{error: "app_not_found", app: app})

          {:error, {:registry_failed, reason}} ->
            Logger.error("Domain remove failed for #{app}: #{inspect(reason)}")
            json(conn, 500, %{error: "domain_remove_failed"})
        end
      end)
    else
      conn
    end
  end

  # List deployed apps joined with their live gateway backend.
  get "/api/apps" do
    conn = require_scope(conn, "vms:read")

    unless conn.halted do
      # mjolnir-xuv: scope alone would list every tenant's app names, URLs and
      # custom domains. Localhost still sees everything (ops); a regular user
      # sees only apps they own. filter_readable/2 also hides legacy nil-owner
      # entries from regular users, consistent with Policy.App.authorize/3.
      user = %{user_id: conn.assigns[:user_id]}

      apps =
        Mjolnir.API.Domains.list_apps()
        |> Mjolnir.Policy.App.filter_readable(user)
        |> Enum.map(&Map.delete(&1, :owner_id))

      json(conn, 200, %{apps: apps})
    else
      conn
    end
  end

  # Host-escrowed deploy secrets. Merge only; responses never include values.
  put "/api/apps/:app/secrets" do
    conn = require_scope(conn, "vms:spawn")

    unless conn.halted do
      authorize_app(conn, app, :set_secrets, fn _entry ->
        case parse_secret_entries(conn.body_params) do
          {:ok, entries} ->
            case Mjolnir.Deploy.Secrets.put(app, entries) do
              {:ok, result} -> json(conn, 200, result)
              {:error, reason} -> secret_error(conn, reason)
            end

          :error ->
            json(conn, 400, %{error: "entries_required"})
        end
      end)
    else
      conn
    end
  end

  get "/api/apps/:app/secrets" do
    conn = require_scope(conn, "vms:read")

    unless conn.halted do
      authorize_app(conn, app, :read, fn _entry ->
        case Mjolnir.Deploy.Secrets.list_keys(app) do
          {:ok, result} -> json(conn, 200, result)
          {:error, reason} -> secret_error(conn, reason)
        end
      end)
    else
      conn
    end
  end

  delete "/api/apps/:app/secrets/:key" do
    conn = require_scope(conn, "vms:spawn")

    unless conn.halted do
      authorize_app(conn, app, :unset_secrets, fn _entry ->
        case Mjolnir.Deploy.Secrets.delete(app, key) do
          {:ok, result} -> json(conn, 200, result)
          {:error, reason} -> secret_error(conn, reason)
        end
      end)
    else
      conn
    end
  end

  # Issue a public HTTP-01 cert for a CNAME'd custom domain (mjolnir-r7b3.3).
  # Issuance runs on the host; the client never sees PEMs. Wildcard refuse
  # happens before the app lookup so a `*.` name is never confused with
  # app_not_found. Ownership is the same check as :set_domain.
  post "/api/certs/issue" do
    conn = require_scope(conn, "vms:spawn")

    unless conn.halted do
      case conn.body_params["fqdn"] do
        fqdn when is_binary(fqdn) and fqdn != "" ->
          if String.starts_with?(String.trim(fqdn), "*.") do
            json(conn, 400, %{
              error: "wildcard_not_supported",
              detail: "HTTP-01 cannot issue wildcards (v1)"
            })
          else
            case app_for_domain(fqdn) do
              nil ->
                json(conn, 404, %{error: "app_not_found", fqdn: fqdn})

              entry ->
                authorize_app(conn, entry.app_name, :issue_cert, fn _entry ->
                  case Mjolnir.API.Certs.issue(fqdn) do
                    {:ok, result} ->
                      json(conn, 200, result)

                    {:error, :wildcard_not_supported} ->
                      json(conn, 400, %{
                        error: "wildcard_not_supported",
                        detail: "HTTP-01 cannot issue wildcards (v1)"
                      })

                    {:error, :fqdn_required} ->
                      json(conn, 400, %{error: "fqdn is required"})

                    {:error, {:issue_failed, _code, output}} ->
                      Logger.error("Cert issue failed for #{fqdn}: #{output}")
                      json(conn, 500, %{error: "cert_issue_failed"})

                    {:error, {:ensure_failed, reason}} ->
                      Logger.error("Cert install failed for #{fqdn}: #{inspect(reason)}")
                      json(conn, 500, %{error: "cert_install_failed"})

                    {:error, reason} ->
                      Logger.error("Cert issue failed for #{fqdn}: #{inspect(reason)}")
                      json(conn, 500, %{error: "cert_issue_failed"})
                  end
                end)
            end
          end

        _ ->
          json(conn, 400, %{error: "fqdn is required"})
      end
    else
      conn
    end
  end

  # List installed [[cert]] entries (no PEMs).
  get "/api/certs" do
    conn = require_scope(conn, "vms:read")

    unless conn.halted do
      user = %{user_id: conn.assigns[:user_id]}

      owned_hosts =
        Mjolnir.API.Domains.list_apps()
        |> Mjolnir.Policy.App.filter_readable(user)
        |> Enum.map(& &1.custom_domain)
        |> Enum.filter(&is_binary/1)
        |> MapSet.new(&String.downcase/1)

      case Mjolnir.API.Certs.list() do
        {:ok, certs} ->
          visible =
            if user.user_id == "localhost" do
              certs
            else
              Enum.filter(certs, fn c ->
                host = c.host || ""
                MapSet.member?(owned_hosts, String.downcase(host))
              end)
            end

          json(conn, 200, %{certs: visible})

        {:error, reason} ->
          Logger.error("Cert list failed: #{inspect(reason)}")
          json(conn, 500, %{error: "cert_list_failed"})
      end
    else
      conn
    end
  end

  # MCP endpoint — Model Context Protocol for AI agent access
  forward("/mcp", to: Mjolnir.MCP.Plug)

  # Forge — host config reconciler. See docs/plans/host-reconcile.md.
  forward("/api/forge", to: Mjolnir.Forge.API)

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  @parsers_opts Plug.Parsers.init(parsers: [:json], json_decoder: Jason)
  defp maybe_parse_body(%{path_info: ["mcp" | _]} = conn, _opts), do: conn
  defp maybe_parse_body(%{path_info: ["api", "sites" | _]} = conn, _opts), do: conn
  # /api/deploy carries a raw gzipped-tar body — bypass the JSON parser so the
  # bytes arrive intact for erl_tar to decompress+extract.
  defp maybe_parse_body(%{path_info: ["api", "deploy"]} = conn, _opts), do: conn
  defp maybe_parse_body(conn, _opts), do: Plug.Parsers.call(conn, @parsers_opts)

  defp spawn_rejecting_memory_snapshot(opts) do
    name = opts[:snapshot]

    if is_binary(name) and Mjolnir.MemorySnapshot.memory_snapshot?(name) do
      {:error, {:memory_snapshot_requires_thaw, name}}
    else
      Mjolnir.VM.spawn(opts)
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp parse_secret_entries(%{"entries" => entries})
       when is_map(entries) and map_size(entries) > 0 do
    {:ok, entries}
  end

  defp parse_secret_entries(%{"key" => key, "value" => value})
       when is_binary(key) and is_binary(value) do
    {:ok, %{key => value}}
  end

  defp parse_secret_entries(_), do: :error

  defp secret_error(conn, :empty), do: json(conn, 400, %{error: "entries_required"})
  defp secret_error(conn, :not_found), do: json(conn, 404, %{error: "secret_not_found"})
  defp secret_error(conn, :invalid_file), do: json(conn, 500, %{error: "secrets_file_invalid"})

  defp secret_error(conn, {:invalid_key, key}) do
    json(conn, 400, %{error: "invalid_key", key: key})
  end

  defp secret_error(conn, {:invalid_value, key}) do
    json(conn, 400, %{error: "invalid_value", key: key})
  end

  defp secret_error(conn, {:write_failed, reason}) do
    Logger.error("Deploy secrets write failed: #{inspect(reason)}")
    json(conn, 500, %{error: "secrets_write_failed"})
  end

  defp secret_error(conn, {:read_failed, reason}) do
    Logger.error("Deploy secrets read failed: #{inspect(reason)}")
    json(conn, 500, %{error: "secrets_read_failed"})
  end

  defp secret_error(conn, reason) do
    Logger.error("Deploy secrets failed: #{inspect(reason)}")
    json(conn, 500, %{error: "secrets_failed"})
  end

  defp app_for_domain(fqdn) do
    want = fqdn |> String.trim() |> String.trim_trailing(".") |> String.downcase()

    Enum.find(Mjolnir.Deploy.Registry.list(), fn e ->
      is_binary(e.custom_domain) and
        String.downcase(String.trim_trailing(String.trim(e.custom_domain), ".")) == want
    end)
  end

  defp handle_adopt(conn, app) do
    user = %{user_id: conn.assigns[:user_id]}
    vm_id = conn.body_params["service_vm_id"]
    port = conn.body_params["port"]
    snap = conn.body_params["release_snapshot"]
    force? = conn.body_params["force"] in [true, "true"]

    cond do
      not is_binary(vm_id) or vm_id == "" ->
        json(conn, 400, %{error: "service_vm_id is required"})

      not is_integer(port) or port < 1 or port > 65_535 ->
        json(conn, 400, %{error: "port must be an integer 1..65535"})

      true ->
        case Mjolnir.Deploy.Registry.get(app) do
          {:ok, entry} ->
            case Mjolnir.Policy.App.authorize(:adopt, user, entry) do
              :ok ->
                do_adopt(conn, app, vm_id, port, snap, force?)

              :error ->
                json(conn, 404, %{error: "app_not_found", app: app})
            end

          {:error, :not_found} ->
            case Mjolnir.Policy.App.authorize(:deploy_new, user, nil) do
              :ok ->
                do_adopt(conn, app, vm_id, port, snap, force?)

              :error ->
                json(conn, 404, %{error: "app_not_found", app: app})
            end
        end
    end
  end

  defp do_adopt(conn, app, vm_id, port, snap, force?) do
    opts = [
      owner_id: conn.assigns[:user_id],
      force: force?
    ]

    opts =
      if is_binary(snap) and snap != "", do: Keyword.put(opts, :release_snapshot, snap), else: opts

    case Mjolnir.API.Adopt.adopt(app, vm_id, port, opts) do
      {:ok, entry} ->
        json(conn, 200, %{
          app: entry.app_name,
          service_vm_id: entry.service_vm_id,
          port: entry.port,
          release_snapshot: entry.release_snapshot,
          stateful: entry.stateful
        })

      {:error, :vm_not_found} ->
        json(conn, 404, %{error: "vm_not_found"})

      {:error, :app_exists} ->
        json(conn, 409, %{error: "app_exists"})

      {:error, :stateful_vm_mismatch} ->
        json(conn, 409, %{error: "stateful_vm_mismatch"})

      {:error, {:snapshot_failed, reason}} ->
        Logger.error("Adopt snapshot failed for #{app}: #{inspect(reason)}")
        json(conn, 500, %{error: "snapshot_failed"})

      {:error, {:registry_failed, reason}} ->
        Logger.error("Adopt registry failed for #{app}: #{inspect(reason)}")
        json(conn, 500, %{error: "adopt_failed"})
    end
  end

  # --- POST /api/deploy ------------------------------------------------------

  # Cap on the total decompressed-tar upload we buffer in memory (256 MiB).
  @deploy_max_body 256 * 1024 * 1024

  defp handle_deploy(conn) do
    with {:ok, body, conn} <- read_full_body(conn),
         {:ok, requested_name} <- deploy_app_name(conn),
         dest = deploy_src_dest(requested_name),
         {:ok, app_dir} <- extract_source(body, dest) do
      app_name = resolve_app_name(requested_name, app_dir)
      deployer = conn.assigns[:user_id]
      memory_mb = deploy_memory_mb(conn)
      custom_domain = deploy_domain(conn)

      # mjolnir-xuv: a redeploy of an EXISTING app requires ownership. Checked
      # here, not at the route, because the app name comes from the uploaded
      # source. Must run before send_chunked/2 — once the response is chunked
      # we can no longer send a 403/404 status.
      authorize_deploy(conn, app_name, fn _entry ->
        do_deploy(conn, app_name, app_dir, deployer, memory_mb, custom_domain)
      end)
    else
      {:error, :too_large} ->
        json(conn, 413, %{error: "source_too_large", limit_bytes: @deploy_max_body})

      {:error, :bad_app_name} ->
        json(conn, 400, %{error: "invalid X-App-Name"})

      {:error, {:extract_failed, reason}} ->
        json(conn, 400, %{error: "invalid_source_archive", reason: inspect(reason)})

      {:error, reason} ->
        Logger.error("Deploy request failed: #{inspect(reason)}")
        json(conn, 400, %{error: "deploy_request_failed", reason: inspect(reason)})
    end
  end

  # Streams build progress as chunked JSON. Split out of handle_deploy/1 so the
  # ownership check (mjolnir-xuv) can still return a 403/404 status — once
  # send_chunked/2 runs, the status is committed and cannot be changed.
  defp do_deploy(conn, app_name, app_dir, deployer, memory_mb, custom_domain) do
    conn = send_chunked(conn, 200)

    # The evolving conn is held in the process dictionary rather than an Agent.
    #
    # This used to be an Agent, and `on_progress` did the chunk/2 inside
    # Agent.update — i.e. from the AGENT's process. Bandit requires every write
    # to come from the process that owns the stream, so the first progress line
    # raised "Adapter functions must be called by stream owner", killing the
    # request; the client saw "unexpected EOF during chunk size line" and every
    # deploy failed before the build even started.
    #
    # The Agent bought nothing: Orchestrator.deploy/3 runs synchronously right
    # here and calls `on_progress` from this very process, so a plain
    # per-process cell is both correct and one less hop. (Same reason
    # Mjolnir.VM uses Process.put for :boot_partial.)
    Process.put(:deploy_conn, conn)

    on_progress = fn stage, line ->
      current = Process.get(:deploy_conn)

      case chunk(current, Jason.encode!(%{stage: stage, line: line}) <> "\n") do
        {:ok, next} -> Process.put(:deploy_conn, next)
        {:error, _} -> :ok
      end
    end

    result =
      Mjolnir.Deploy.Orchestrator.deploy(app_name, app_dir,
        deployer: deployer,
        memory_mb: memory_mb,
        custom_domain: custom_domain,
        on_progress: on_progress
      )

    final =
      case result do
        {:ok, r} ->
          Map.put(r, :ok, true)

        {:error, %{stage: stage, reason: reason}} ->
          %{ok: false, stage: stage, error: inspect(reason)}
      end

    conn = Process.delete(:deploy_conn) || conn

    case chunk(conn, Jason.encode!(final) <> "\n") do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  # Read the entire (unparsed) request body, bounded by @deploy_max_body.
  defp read_full_body(conn, acc \\ "") do
    if byte_size(acc) > @deploy_max_body do
      {:error, :too_large}
    else
      case read_body(conn, length: 8_000_000, read_length: 1_000_000) do
        {:ok, data, conn} -> {:ok, acc <> data, conn}
        {:more, data, conn} -> read_full_body(conn, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp deploy_app_name(conn) do
    case get_req_header(conn, "x-app-name") do
      [name | _] when is_binary(name) and name != "" ->
        case Validation.validate_safe_name(name, "X-App-Name") do
          {:ok, safe} -> {:ok, safe}
          {:error, _} -> {:error, :bad_app_name}
        end

      _ ->
        # Deferred to extract_source, which derives from the tar's top dir.
        {:ok, :derive}
    end
  end

  defp deploy_memory_mb(conn) do
    case get_req_header(conn, "x-memory-mb") do
      [val | _] ->
        case Integer.parse(to_string(val)) do
          {n, ""} -> Validation.validate_integer(n, 256, 128, 32_768)
          _ -> 256
        end

      _ ->
        256
    end
  end

  defp deploy_domain(conn) do
    case get_req_header(conn, "x-domain") do
      [d | _] when is_binary(d) and d != "" -> d
      _ -> nil
    end
  end

  # A provided X-App-Name wins; otherwise derive from the extracted top dir.
  defp resolve_app_name(name, _app_dir) when is_binary(name), do: name

  defp resolve_app_name(:derive, app_dir) do
    case Path.basename(app_dir) do
      "" -> "app"
      "." -> "app"
      base -> base
    end
  end

  defp deploy_src_dest(:derive), do: deploy_src_dest("app")

  defp deploy_src_dest(app_name) do
    base = Application.get_env(:mjolnir, :deploy_src_dir, "/var/lib/mjolnir/deploy/src")
    Path.join(base, safe_slug(app_name))
  end

  defp safe_slug(app_name) do
    app_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "_")
  end

  # Extract the gzipped tar into `dest` (wiped first) and locate the app root —
  # the directory containing package.json (dest itself, or its single subdir).
  defp extract_source(body, dest) do
    _ = File.rm_rf(dest)

    with :ok <- File.mkdir_p(dest),
         :ok <- erl_tar_extract(body, dest) do
      {:ok, app_root(dest)}
    else
      {:error, reason} -> {:error, {:extract_failed, reason}}
    end
  end

  defp erl_tar_extract(body, dest) do
    case :erl_tar.extract({:binary, body}, [:compressed, {:cwd, String.to_charlist(dest)}]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp app_root(dest) do
    cond do
      File.exists?(Path.join(dest, "package.json")) ->
        dest

      true ->
        case File.ls(dest) do
          {:ok, [only]} ->
            sub = Path.join(dest, only)
            if File.dir?(sub), do: sub, else: dest

          _ ->
            dest
        end
    end
  end

  # Run the trash restore + map its result to a response. Split out so the
  # endpoint body stays focused on the ownership decision.
  defp restore_from_trash(conn, id) do
    case Mjolnir.Storage.restore_from_trash(id) do
      {:ok, result} ->
        json(conn, 200, result)

      {:error, :already_present} ->
        json(conn, 409, %{error: "already_present", detail: "a live VM with this id exists"})

      {:error, :not_found} ->
        json(conn, 404, %{error: "not_in_trash"})

      {:error, reason} ->
        json(conn, 500, %{error: "restore_failed", reason: inspect(reason)})
    end
  end

  # Health response encoders — convert {:degraded, reason} / {:dead, reason}
  # tuples into JSON-friendly maps, and roll up overall status.

  defp encode_health_report(%{vm_id: id, overall: overall, checks: checks} = report) do
    %{
      vm_id: id,
      overall: Atom.to_string(overall),
      checks: Enum.map(checks, &encode_health_check/1)
    }
    |> put_secrets_unlock_failed(Map.get(report, :secrets_unlock_failed))
  end

  # mjolnir-3v2: informational field, absent entirely when there's nothing to
  # report (not :managed, or the last unlock succeeded/was skipped) so old
  # clients see no shape change.
  defp put_secrets_unlock_failed(map, nil), do: map

  defp put_secrets_unlock_failed(map, %{reason: reason, at: at}) do
    Map.put(map, :secrets_unlock_failed, %{reason: reason, at: at})
  end

  defp encode_health_check(%{level: level, name: name, status: status} = entry) do
    base = %{
      level: level,
      name: name,
      status: encode_health_status(status)
    }

    case Map.get(entry, :action) do
      nil -> base
      action -> Map.put(base, :action, inspect(action))
    end
  end

  defp encode_health_status(:ok), do: %{state: "ok"}
  defp encode_health_status({:degraded, r}), do: %{state: "degraded", reason: inspect(r)}
  defp encode_health_status({:dead, r}), do: %{state: "dead", reason: inspect(r)}

  defp encode_host_entry(%{name: name, status: status} = entry) do
    base = %{name: name, status: encode_health_status(status)}

    case Map.get(entry, :detail) do
      nil -> base
      d -> Map.put(base, :detail, to_string(d))
    end
  end

  # Build a metadata selector from repeatable `?metadata.<key>=<value>` params.
  defp metadata_selector(query_params) when is_map(query_params) do
    query_params
    |> Enum.flat_map(fn
      {"metadata." <> key, value} when key != "" and is_binary(value) -> [{key, value}]
      _ -> []
    end)
    |> Map.new()
  end

  defp metadata_selector(_), do: %{}

  # Every pair must match. An empty selector matches everything, so the
  # unfiltered list keeps its existing behaviour.
  defp metadata_matches?(_metadata, selector) when map_size(selector) == 0, do: true

  defp metadata_matches?(metadata, selector) when is_map(metadata) do
    Enum.all?(selector, fn {k, v} -> Map.get(metadata, k) == v end)
  end

  defp metadata_matches?(_metadata, _selector), do: false

  # Compare-and-delete fence. Absent header means unconditional, which is the
  # pre-existing contract; a present-but-unparseable one is a client error, not
  # a licence to delete unconditionally.
  defp check_if_match(conn, vm_id) do
    case Plug.Conn.get_req_header(conn, "if-match") do
      [] ->
        :ok

      [raw | _] ->
        case Integer.parse(String.trim(raw)) do
          {generation, ""} when generation > 0 -> compare_generation(vm_id, generation)
          _ -> {:error, :malformed}
        end
    end
  end

  defp compare_generation(vm_id, expected) do
    case Mjolnir.StateStore.get(vm_id) do
      {:ok, %{generation: ^expected}} -> :ok
      {:ok, %{generation: current}} -> {:error, :conflict, current}
      # No durable record to fence against — let the delete proceed and report
      # its own not_found rather than inventing a conflict.
      :not_found -> :ok
    end
  end

  defp validate_mount_path(path) do
    allowed = Application.get_env(:mjolnir, :allowed_mount_prefixes, [])
    expanded = Path.expand(path)

    cond do
      allowed == [] ->
        {:error, "extra_mounts disabled: no allowed_mount_prefixes configured"}

      String.contains?(expanded, "..") ->
        {:error, "mount path must not contain '..'"}

      Enum.any?(allowed, &String.starts_with?(expanded, &1)) ->
        {:ok, expanded}

      true ->
        {:error, "mount path not in allowed prefix list"}
    end
  end

  defp host_overall(_mod, entries) do
    cond do
      Enum.any?(entries, fn e -> match?({:dead, _}, e.status) end) -> "dead"
      Enum.any?(entries, fn e -> match?({:degraded, _}, e.status) end) -> "degraded"
      true -> "ok"
    end
  end
end
