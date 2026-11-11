defmodule Mjolnir.Aie.Guild do
  @moduledoc """
  BEAM guild admission gate for AIE execute.

  Called after a successful occupancy try-lock. Membership is not a
  Biscuit Datalog fact: `Biscuit.authorize/6` stays `inject_holder` only.
  A token-authored `member` fact does not admit. Personal-fp offers skip
  only the guild portion (roster + delegation).
  """

  alias Mjolnir.Aie.{Delegate, Offer}
  alias Mjolnir.Aie.Guild.Roster
  alias Mjolnir.AIE.Pending

  @spec admit(map()) :: :ok | {:error, atom()}
  def admit(args) when is_map(args) do
    now = get(args, :now, System.system_time(:second))

    with {:ok, offer} <- take_offer(args),
         {:ok, holder_fp} <- take_holder(args),
         {:ok, pending_id} <- take_bin(args, :pending_id, :unknown_pending),
         {:ok, _attempt_id} <- take_bin(args, :attempt_id, :missing_attempt),
         :ok <- check_deadline(args),
         :ok <- check_biscuit(args),
         {:ok, row} <- fetch_pending(args, pending_id) do
      if personal?(offer) do
        :ok
      else
        guild_admit(offer, holder_fp, row, args, now)
      end
    end
  end

  defp guild_admit(offer, holder_fp, row, args, now) do
    guild = offer.guild

    with {:ok, member_pk} <- selector(row),
         {:ok, rec} <- Delegate.current(member_pk, holder_fp),
         :ok <- Delegate.authorize_grant(rec, guild, member_pk, holder_fp, now),
         {:ok, %{member?: true}} <- Roster.lookup(guild, member_pk, roster_opts(args, now)) do
      :ok
    else
      {:ok, %{member?: false}} -> {:error, :not_member}
      {:error, :not_found} -> {:error, :no_delegation}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _} -> {:error, :refused}
    end
  end

  defp personal?(%Offer{guild: guild}) when guild in [nil, ""], do: true
  defp personal?(%{guild: guild}) when guild in [nil, ""], do: true
  defp personal?(_), do: false

  defp selector(%{frame: frame}) when is_map(frame) do
    raw = frame["member_pk"] || frame[:member_pk]
    decode_member_pk(raw)
  end

  defp selector(_), do: {:error, :missing_selector}

  defp decode_member_pk(pk) when is_binary(pk) and byte_size(pk) == 32, do: {:ok, pk}

  defp decode_member_pk(b64) when is_binary(b64) and b64 != "" do
    cond do
      match?({:ok, <<_::binary-size(32)>>}, Base.decode64(b64)) ->
        {:ok, elem(Base.decode64(b64), 1)}

      match?({:ok, <<_::binary-size(32)>>}, Base.decode16(b64, case: :mixed)) ->
        {:ok, elem(Base.decode16(b64, case: :mixed), 1)}

      true ->
        {:error, :missing_selector}
    end
  end

  defp decode_member_pk(_), do: {:error, :missing_selector}

  defp take_offer(args) do
    case get(args, :offer) do
      %Offer{} = offer -> {:ok, offer}
      %{guild: _} = offer -> {:ok, offer}
      _ -> {:error, :missing_offer}
    end
  end

  defp take_holder(args) do
    case get(args, :holder_fp) do
      fp when is_binary(fp) and byte_size(fp) == 32 -> {:ok, fp}
      _ -> {:error, :missing_holder}
    end
  end

  defp take_bin(args, key, error) do
    case get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp check_deadline(args) do
    now_mono = get(args, :now_mono_ms, System.monotonic_time(:millisecond))
    deadline = get(args, :deadline_mono_ms) || get(args, :deadline)

    cond do
      is_integer(deadline) and now_mono >= deadline -> {:error, :deadline}
      true -> :ok
    end
  end

  defp check_biscuit(args) do
    # Conjunction with Biscuit is proven by the caller. A missing flag is
    # treated as already verified; an explicit false refuses. Token-authored
    # member facts are ignored.
    _ = get(args, :token_member)

    case get(args, :biscuit_ok, true) do
      true -> :ok
      _ -> {:error, :biscuit}
    end
  end

  defp fetch_pending(args, pending_id) do
    server = get(args, :pending, Pending)

    case Pending.fetch(server, pending_id) do
      {:ok, row} -> {:ok, row}
      {:error, :unknown} -> {:error, :unknown_pending}
    end
  end

  defp roster_opts(args, now) do
    [
      now: now,
      fetch: get(args, :roster_fetch),
      timeout_ms: get(args, :roster_timeout_ms, 1_000),
      max_age_s: get(args, :roster_max_age_s)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end
end
