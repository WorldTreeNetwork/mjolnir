defmodule Mjolnir.AIE.Admit do
  @moduledoc """
  HTTP pipeline for `/run/mjolnir/aie-admit.sock`.

  Not `Mjolnir.API.OperatorPipeline`. Connections are not operators
  and cannot spawn, exec, kill, or snapshot VMs. Enqueue and admission
  only. Socket mode `0660` owner root group `mjolnir-aie`.
  """

  use Plug.Router

  @socket_mode 0o660
  @socket_group "mjolnir-aie"

  plug(:assign_pending)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["*/*"])
  plug(:dispatch)

  @spec socket_mode() :: non_neg_integer()
  def socket_mode, do: @socket_mode

  @spec socket_group() :: String.t()
  def socket_group, do: @socket_group

  @spec apply_socket_perms(Path.t()) :: :ok | {:error, term()}
  def apply_socket_perms(path) when is_binary(path) do
    with :ok <- File.chmod(path, @socket_mode) do
      apply_group(path)
      :ok
    end
  end

  post "/enqueue" do
    pending = conn.private[:aie_pending]
    body = conn.body_params
    nonce = body["nonce"]
    frame = body["frame"] || %{}

    cond do
      not is_binary(nonce) or nonce == "" ->
        json(conn, 400, %{error: "nonce_required"})

      true ->
        case Mjolnir.AIE.Pending.enqueue(pending, nonce, frame) do
          {:ok, pending_id} ->
            json(conn, 200, %{pending_id: pending_id, status: "pending"})

          {:error, reason} ->
            json(conn, 400, %{error: Atom.to_string(reason)})
        end
    end
  end

  post "/admission" do
    pending = conn.private[:aie_pending]
    body = conn.body_params
    pending_id = body["pending_id"]
    attempt_id = body["attempt_id"]

    cond do
      not is_binary(pending_id) or not is_binary(attempt_id) ->
        json(conn, 400, %{error: "pending_id_and_attempt_id_required"})

      true ->
        case Mjolnir.AIE.Pending.admit(pending, pending_id, attempt_id, body) do
          {:ok, payload} ->
            json(conn, 200, payload)

          {:error, reason} ->
            json(conn, 400, %{error: Atom.to_string(reason)})
        end
    end
  end

  match _ do
    conn
    |> Plug.Conn.put_status(404)
    |> json_raw(%{error: "not_found"})
  end

  defp assign_pending(conn, _opts) do
    case conn.private[:aie_pending] do
      nil -> Plug.Conn.put_private(conn, :aie_pending, Mjolnir.AIE.Pending)
      _ -> conn
    end
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
    |> Plug.Conn.halt()
  end

  defp json_raw(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(conn.status || 200, Jason.encode!(body))
    |> Plug.Conn.halt()
  end

  defp apply_group(path) do
    case System.cmd("getent", ["group", @socket_group], stderr_to_stdout: true) do
      {out, 0} ->
        gid =
          out
          |> String.split(":")
          |> Enum.at(2)
          |> to_string()
          |> String.trim()
          |> Integer.parse()

        case gid do
          {n, _} -> File.chgrp(path, n)
          :error -> :ok
        end

      _ ->
        :ok
    end
  end
end
