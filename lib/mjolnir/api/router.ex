defmodule Mjolnir.API.Router do
  @moduledoc """
  HTTP API router for Mjolnir VM management.

  Provides RESTful endpoints for spawning, listing, inspecting,
  executing commands in, and stopping microVMs. Authentication is
  handled by `Mjolnir.API.Auth` (JWT or localhost bypass).
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

      opts =
        case conn.body_params["secrets_mode"] do
          "persistent" -> Map.put(opts, :secrets_mode, :persistent)
          "ephemeral" -> Map.put(opts, :secrets_mode, :ephemeral)
          "none" -> Map.put(opts, :secrets_mode, :none)
          nil -> opts
          _ -> Map.put(opts, :_validation_error, "secrets_mode must be 'persistent', 'ephemeral', or 'none'")
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
                  _ -> {:halt, {:error, "extra_mounts entries must have string 'tag' and 'path' fields"}}
                end
              end)

            case parsed do
              {:ok, entries} -> Map.put(opts, :extra_mounts, Enum.reverse(entries))
              {:error, msg} -> Map.put(opts, :_validation_error, msg)
            end

          _ ->
            Map.put(opts, :_validation_error, "extra_mounts must be an array")
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
          case Mjolnir.VM.spawn(opts) do
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

      vms =
        Mjolnir.VM.list()
        |> Enum.filter(fn vm ->
          user_id == "localhost" or vm.owner_id == user_id
        end)
        |> Enum.map(&Views.render_vm_summary/1)

      json(conn, 200, %{vms: vms})
    else
      conn
    end
  end

  # WebSocket PTY endpoint (must be before /api/vms/:id to avoid being captured)
  get "/api/vms/:id/pty" do
    conn = require_scope(conn, "pty:connect")

    unless conn.halted do
      authorize_vm(conn, id, :pty, fn _vm ->
        Mjolnir.API.PtyHandler.call(conn, id)
      end)
    else
      conn
    end
  end

  # Get VM details
  get "/api/vms/:id" do
    conn = require_scope(conn, "vms:read")

    unless conn.halted do
      authorize_vm(conn, id, :read, fn vm ->
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
            scrollback_lines = Validation.validate_scrollback_lines(conn.query_params["scrollback_lines"])

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
        with {:ok, validated_name} <- Validation.validate_session_name(session_name, "session_name"),
             {:ok, command} <- Validation.validate_command(conn.body_params["command"]) do
          timeout_ms = Validation.validate_timeout(conn.body_params["timeout_ms"], 30_000, 300_000)

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

        # Validate from_vm_id ownership when not "external"
        authorized =
          if from_vm_id == "external" do
            true
          else
            user = %{user_id: conn.assigns[:user_id]}

            case Mjolnir.VM.get(from_vm_id) do
              {:ok, from_vm} -> Mjolnir.Policy.VM.authorize(:message, user, from_vm) == :ok
              {:error, :not_found} -> false
            end
          end

        if authorized do
          case Mjolnir.VM.deliver_message(id, from_vm_id, payload) do
            :ok ->
              json(conn, 200, %{ok: true})

            {:error, :not_found} ->
              json(conn, 404, %{error: "not_found"})

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
        case Mjolnir.VM.stop(id) do
          :ok ->
            json(conn, 200, %{ok: true})

          {:error, :not_found} ->
            json(conn, 404, %{error: "not_found"})

          {:error, reason} ->
            Logger.error("VM stop failed for #{id}: #{inspect(reason)}")
            json(conn, 500, %{error: "stop_failed"})
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
                json(conn, 201, metadata)

              {:error, {:snapshot_exists, _}} ->
                json(conn, 409, %{error: "name unavailable"})

              {:error, :not_found} ->
                json(conn, 404, %{error: "vm not_found"})

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

  # List all snapshots
  get "/api/snapshots" do
    conn = require_scope(conn, "snapshots:read")

    unless conn.halted do
      case Mjolnir.BTRFS.list_snapshots() do
        {:ok, snapshots} ->
          user_id = conn.assigns[:user_id]

          filtered =
            Enum.filter(snapshots, fn meta ->
              user_id == "localhost" or meta[:owner_id] == user_id
            end)

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
                :ok -> json(conn, 200, metadata)
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
                      Logger.error("Snapshot delete failed for '#{validated_name}': #{inspect(reason)}")
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
  defp maybe_parse_body(conn, _opts), do: Plug.Parsers.call(conn, @parsers_opts)

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  # Health response encoders — convert {:degraded, reason} / {:dead, reason}
  # tuples into JSON-friendly maps, and roll up overall status.

  defp encode_health_report(%{vm_id: id, overall: overall, checks: checks}) do
    %{
      vm_id: id,
      overall: Atom.to_string(overall),
      checks: Enum.map(checks, &encode_health_check/1)
    }
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
