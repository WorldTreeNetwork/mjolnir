defmodule Mjolnir.Aie.Guild.Roster do
  @moduledoc """
  Authenticated guild membership adapter.

  Host config `:aie_guild_rosters` maps each guild/keyspace id to
  `%{endpoint: url, authority_pubkey: <<32 bytes>>}`. Unconfigured
  guilds fail closed. The adapter attests membership only; a stub that
  returns member without a configured authority does not satisfy this.
  """

  alias Mjolnir.Sites.{IdentiKey, MultiSig}

  @domain "mjolnir/aie-roster/v1"
  @default_max_age_s 60
  @future_skew_s 5

  @spec lookup(String.t(), binary(), keyword()) ::
          {:ok, %{member?: boolean(), issued_at: integer()}} | {:error, atom()}
  def lookup(guild, member_pk, opts \\ [])

  def lookup(guild, member_pk, opts)
      when is_binary(guild) and is_binary(member_pk) and byte_size(member_pk) == 32 do
    with {:ok, cfg} <- config_for(guild),
         {:ok, body} <- fetch_body(cfg, guild, member_pk, opts),
         {:ok, evidence} <- verify_body(cfg, guild, member_pk, body),
         :ok <- freshness(evidence, opts) do
      {:ok, evidence}
    end
  end

  def lookup(_, _, _), do: {:error, :malformed}

  @spec signing_bytes(String.t(), binary(), boolean(), integer()) :: binary()
  def signing_bytes(guild, member_pk, member?, issued_at)
      when is_binary(guild) and byte_size(member_pk) == 32 and is_boolean(member?) and
             is_integer(issued_at) do
    member_byte = if member?, do: <<1>>, else: <<0>>

    fields = [
      guild,
      member_pk,
      member_byte,
      <<issued_at::unsigned-big-64>>
    ]

    IO.iodata_to_binary([
      @domain | Enum.map(fields, &<<byte_size(&1)::unsigned-big-32, &1::binary>>)
    ])
  end

  @spec serialize(String.t(), binary(), boolean(), integer(), binary()) :: binary()
  def serialize(guild, member_pk, member?, issued_at, signature)
      when is_binary(signature) do
    Jason.encode!(%{
      "guild" => guild,
      "member_pk" => Base.encode64(member_pk),
      "member" => member?,
      "issued_at" => issued_at,
      "signature" => MultiSig.to_field(%MultiSig{ed25519: signature})
    })
  end

  defp config_for(guild) do
    map = Application.get_env(:mjolnir, :aie_guild_rosters, %{}) || %{}

    case Map.get(map, guild) || Map.get(map, String.to_atom(guild)) do
      %{authority_pubkey: pk} = cfg when is_binary(pk) and byte_size(pk) == 32 ->
        {:ok, Map.put(cfg, :authority_pubkey, pk)}

      %{authority_pubkey_b64: b64} = cfg when is_binary(b64) ->
        case Base.decode64(b64) do
          {:ok, pk} when byte_size(pk) == 32 ->
            {:ok, Map.put(cfg, :authority_pubkey, pk)}

          _ ->
            {:error, :unconfigured}
        end

      _ ->
        {:error, :unconfigured}
    end
  end

  defp fetch_body(cfg, guild, member_pk, opts) do
    timeout = Keyword.get(opts, :timeout_ms, 1_000)

    case Keyword.get(opts, :fetch) || Application.get_env(:mjolnir, :aie_roster_fetch) do
      fun when is_function(fun, 4) ->
        wrap_fetch(fun.(cfg, guild, member_pk, opts))

      fun when is_function(fun, 3) ->
        wrap_fetch(fun.(guild, member_pk, opts))

      _ ->
        http_fetch(cfg, guild, member_pk, timeout)
    end
  end

  defp wrap_fetch({:ok, body}) when is_binary(body), do: {:ok, body}
  defp wrap_fetch({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp wrap_fetch({:error, _}), do: {:error, :unavailable}
  defp wrap_fetch(_), do: {:error, :malformed}

  defp http_fetch(cfg, guild, member_pk, timeout) do
    endpoint = Map.get(cfg, :endpoint) || Map.get(cfg, "endpoint")

    if is_binary(endpoint) and endpoint != "" do
      try do
        case Req.get(endpoint,
               params: [guild: guild, member_pk: Base.encode64(member_pk)],
               receive_timeout: max(timeout, 1),
               retry: false,
               decode_body: false
             ) do
          {:ok, %{status: 200, body: body}} when is_binary(body) ->
            {:ok, body}

          {:ok, %{status: 200, body: body}} when is_list(body) ->
            {:ok, IO.iodata_to_binary(body)}

          {:error, %{reason: :timeout}} ->
            {:error, :unavailable}

          {:error, _} ->
            {:error, :unavailable}

          _ ->
            {:error, :unavailable}
        end
      rescue
        _ -> {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  end

  defp verify_body(cfg, guild, member_pk, body) do
    with {:ok, raw} <- decode_json(body),
         {:ok, resp_guild} <- fetch_bin(raw, "guild"),
         {:ok, resp_pk} <- decode_pk(raw["member_pk"]),
         {:ok, member?} <- decode_member(raw["member"]),
         {:ok, issued_at} <- decode_issued(raw["issued_at"]),
         {:ok, sig} <- extract_sig(raw) do
      cond do
        resp_guild != guild or resp_pk != member_pk ->
          {:error, :wrong_subject}

        not IdentiKey.verify(
          cfg.authority_pubkey,
          signing_bytes(resp_guild, resp_pk, member?, issued_at),
          sig
        ) ->
          {:error, :unauthenticated}

        true ->
          {:ok, %{member?: member?, issued_at: issued_at}}
      end
    else
      _ ->
        {:error, :malformed}
    end
  end

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, raw} when is_map(raw) -> {:ok, raw}
      _ -> {:error, :malformed}
    end
  end

  defp fetch_bin(raw, key) do
    case raw[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp decode_pk(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, pk} when byte_size(pk) == 32 -> {:ok, pk}
      _ -> :error
    end
  end

  defp decode_pk(_), do: :error

  defp decode_member(true), do: {:ok, true}
  defp decode_member(false), do: {:ok, false}
  defp decode_member(_), do: :error

  defp decode_issued(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp decode_issued(_), do: :error

  defp extract_sig(raw) do
    case MultiSig.from_field(raw["signature"]) do
      %MultiSig{ed25519: sig} when is_binary(sig) -> {:ok, sig}
      _ -> :error
    end
  end

  defp freshness(%{issued_at: issued_at}, opts) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    max_age = Keyword.get(opts, :max_age_s, roster_max_age())

    cond do
      issued_at > now + @future_skew_s -> {:error, :future}
      issued_at < now - max_age -> {:error, :stale}
      true -> :ok
    end
  end

  defp roster_max_age do
    Application.get_env(:mjolnir, :aie_roster_max_age_s, @default_max_age_s)
  end
end
