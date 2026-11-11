defmodule Mjolnir.Aie.Delegate do
  @moduledoc """
  Member-signed AIE delegation leaf (`mjolnir/aie-delegate/v1`) and
  withdrawal (`mjolnir/aie-delegate-withdraw/v1`).

  One SecretStore key `(storage_fp, "aie/delegate/<holder_fp58>")` holds
  the current grant or withdraw tombstone. Sequence of that record is the
  floor. Canonical signing bytes follow the Redeem length-prefix grammar.
  """

  alias Mjolnir.Biscuit
  alias Mjolnir.SecretStore
  alias Mjolnir.Sites.{Crypto, IdentiKey, MultiSig}

  @grant_domain "mjolnir/aie-delegate/v1"
  @withdraw_domain "mjolnir/aie-delegate-withdraw/v1"
  @grant_purpose "aie-execute"
  @withdraw_purpose "aie-withdraw"
  @key_prefix "aie/delegate/"
  @grant_type "aie_delegate"
  @withdraw_type "aie_delegate_withdraw"
  @max_lifetime 86_400
  @issued_skew_s 5

  defstruct [
    :guild,
    :member_pk,
    :holder_fp,
    :purpose,
    :issued_at,
    :expires_at,
    :sequence,
    :signature,
    version: 1,
    type: :grant
  ]

  @type t :: %__MODULE__{
          version: pos_integer(),
          type: :grant | :withdraw,
          guild: String.t(),
          member_pk: binary(),
          holder_fp: binary(),
          purpose: String.t(),
          issued_at: non_neg_integer(),
          expires_at: non_neg_integer(),
          sequence: pos_integer(),
          signature: binary() | nil
        }

  @spec grant_domain() :: String.t()
  def grant_domain, do: @grant_domain

  @spec withdraw_domain() :: String.t()
  def withdraw_domain, do: @withdraw_domain

  @spec grant_type() :: String.t()
  def grant_type, do: @grant_type

  @spec withdraw_type() :: String.t()
  def withdraw_type, do: @withdraw_type

  @spec key_prefix() :: String.t()
  def key_prefix, do: @key_prefix

  @spec key(binary()) :: String.t()
  def key(holder_fp) when is_binary(holder_fp) and byte_size(holder_fp) == 32 do
    @key_prefix <> holder_fp58(holder_fp)
  end

  @spec delegate_key?(String.t()) :: boolean()
  def delegate_key?(key) when is_binary(key), do: String.starts_with?(key, @key_prefix)

  @spec holder_fp58(binary()) :: String.t()
  def holder_fp58(holder_fp) when is_binary(holder_fp) and byte_size(holder_fp) == 32 do
    leading =
      holder_fp
      |> :binary.bin_to_list()
      |> Enum.take_while(&(&1 == 0))
      |> length()

    String.duplicate("1", leading) <> Crypto.base58_encode(holder_fp)
  end

  @spec grant_vector() :: binary()
  def grant_vector do
    signing_bytes(%__MODULE__{
      type: :grant,
      version: 1,
      guild: "g1",
      member_pk: <<0::256>>,
      holder_fp: <<0::256>>,
      purpose: @grant_purpose,
      issued_at: 0,
      expires_at: 86_400,
      sequence: 1
    })
  end

  @spec withdraw_vector() :: binary()
  def withdraw_vector do
    signing_bytes(%__MODULE__{
      type: :withdraw,
      version: 1,
      guild: "g1",
      member_pk: <<0::256>>,
      holder_fp: <<0::256>>,
      purpose: @withdraw_purpose,
      issued_at: 0,
      expires_at: 0,
      sequence: 1
    })
  end

  @spec domain(t()) :: String.t()
  def domain(%__MODULE__{type: :withdraw}), do: @withdraw_domain
  def domain(%__MODULE__{}), do: @grant_domain

  @spec signing_bytes(t()) :: binary()
  def signing_bytes(%__MODULE__{} = rec) do
    fields = [
      <<rec.version::unsigned-big-32>>,
      rec.guild,
      rec.member_pk,
      rec.holder_fp,
      rec.purpose,
      <<rec.issued_at::unsigned-big-64>>,
      <<rec.expires_at::unsigned-big-64>>,
      <<rec.sequence::unsigned-big-64>>
    ]

    IO.iodata_to_binary([
      domain(rec) | Enum.map(fields, &<<byte_size(&1)::unsigned-big-32, &1::binary>>)
    ])
  end

  @spec canonical_signing_bytes(t()) :: binary()
  def canonical_signing_bytes(%__MODULE__{} = rec), do: signing_bytes(rec)

  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = rec) do
    %{
      "type" => type_string(rec.type),
      "version" => rec.version,
      "guild" => rec.guild,
      "member_pk" => Base.encode64(rec.member_pk),
      "holder_fp" => Base.encode64(rec.holder_fp),
      "purpose" => rec.purpose,
      "issued_at" => rec.issued_at,
      "expires_at" => rec.expires_at,
      "sequence" => rec.sequence,
      "signature" => encode_sig(rec.signature)
    }
    |> Jason.encode!()
  end

  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, raw} when is_map(raw) -> parse_map(raw)
      _ -> {:error, :malformed}
    end
  end

  @spec record?(binary()) :: boolean()
  def record?(bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, raw} ->
        raw["type"] in [@grant_type, @withdraw_type]

      _ ->
        false
    end
  end

  @spec sign(t(), IdentiKey.keypair()) :: t()
  def sign(%__MODULE__{} = rec, keypair) do
    %{rec | signature: IdentiKey.sign(keypair, signing_bytes(rec))}
  end

  @spec put(t(), IdentiKey.keypair()) :: :ok | {:error, term()}
  def put(%__MODULE__{} = rec, keypair) do
    signed = sign(rec, keypair)
    storage_fp = IdentiKey.fingerprint(signed.member_pk)
    SecretStore.put(storage_fp, key(signed.holder_fp), serialize(signed))
  end

  @spec current(binary(), binary()) :: {:ok, t()} | {:error, atom()}
  def current(member_pk, holder_fp)
      when is_binary(member_pk) and is_binary(holder_fp) do
    storage_fp = IdentiKey.fingerprint(member_pk)

    case SecretStore.get(storage_fp, key(holder_fp)) do
      :not_found ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :unreadable}

      {:ok, bytes} ->
        with :ok <- SecretStore.verify_envelope(storage_fp, bytes),
             {:ok, rec} <- parse(bytes),
             true <- rec.member_pk == member_pk,
             true <- rec.holder_fp == holder_fp do
          {:ok, rec}
        else
          false -> {:error, :malformed}
          {:error, _} -> {:error, :malformed}
        end
    end
  end

  @spec authorize_grant(t(), String.t(), binary(), binary(), integer()) ::
          :ok | {:error, atom()}
  def authorize_grant(%__MODULE__{} = rec, guild, member_pk, holder_fp, now)
      when is_binary(guild) and is_binary(member_pk) and is_binary(holder_fp) and
             is_integer(now) do
    cond do
      rec.type != :grant or rec.purpose != @grant_purpose ->
        {:error, :tombstoned}

      rec.guild != guild ->
        {:error, :cross_guild}

      rec.member_pk != member_pk ->
        {:error, :member_mismatch}

      rec.holder_fp != holder_fp ->
        {:error, :holder_mismatch}

      not signature_ok?(rec) ->
        {:error, :bad_signature}

      not grant_window?(rec, now) ->
        {:error, :expired}

      true ->
        :ok
    end
  end

  def authorize_grant(_, _, _, _, _), do: {:error, :malformed}

  @spec holder_fingerprint(binary()) :: binary()
  def holder_fingerprint(ed25519_pub) when byte_size(ed25519_pub) == 32 do
    Biscuit.holder_fingerprint(ed25519_pub)
  end

  defp parse_map(raw) do
    with {:ok, type} <- decode_type(raw["type"]),
         {:ok, version} <- decode_u32(raw["version"]),
         {:ok, guild} <- decode_guild(raw["guild"]),
         {:ok, member_pk} <- decode_32(raw["member_pk"]),
         {:ok, holder_fp} <- decode_32(raw["holder_fp"]),
         {:ok, purpose} <- decode_purpose(type, raw["purpose"]),
         {:ok, issued_at} <- decode_u64(raw["issued_at"]),
         {:ok, expires_at} <- decode_u64(raw["expires_at"]),
         {:ok, sequence} <- decode_u64(raw["sequence"]),
         true <- sequence > 0 do
      {:ok,
       %__MODULE__{
         type: type,
         version: version,
         guild: guild,
         member_pk: member_pk,
         holder_fp: holder_fp,
         purpose: purpose,
         issued_at: issued_at,
         expires_at: expires_at,
         sequence: sequence,
         signature: decode_sig(Map.get(raw, "signature"))
       }}
    else
      _ -> {:error, :malformed}
    end
  end

  defp decode_type(@grant_type), do: {:ok, :grant}
  defp decode_type(@withdraw_type), do: {:ok, :withdraw}
  defp decode_type(_), do: :error

  defp decode_purpose(:grant, @grant_purpose), do: {:ok, @grant_purpose}
  defp decode_purpose(:withdraw, @withdraw_purpose), do: {:ok, @withdraw_purpose}
  defp decode_purpose(_, _), do: :error

  defp decode_guild(guild) when is_binary(guild) and guild != "", do: {:ok, guild}
  defp decode_guild(_), do: :error

  defp decode_32(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bin} when byte_size(bin) == 32 -> {:ok, bin}
      _ -> :error
    end
  end

  defp decode_32(_), do: :error

  defp decode_u32(n) when is_integer(n) and n >= 0 and n <= 0xFFFFFFFF, do: {:ok, n}
  defp decode_u32(_), do: :error

  defp decode_u64(n) when is_integer(n) and n >= 0 and n <= 0xFFFFFFFFFFFFFFFF, do: {:ok, n}
  defp decode_u64(_), do: :error

  defp type_string(:withdraw), do: @withdraw_type
  defp type_string(_), do: @grant_type

  defp encode_sig(nil), do: nil
  defp encode_sig(<<>>), do: nil

  defp encode_sig(bin) when is_binary(bin) do
    MultiSig.to_field(%MultiSig{ed25519: bin})
  end

  defp decode_sig(field) do
    case MultiSig.from_field(field) do
      nil -> nil
      %MultiSig{ed25519: ed} -> ed
    end
  end

  defp signature_ok?(%__MODULE__{signature: sig, member_pk: pk} = rec)
       when is_binary(sig) and is_binary(pk) do
    IdentiKey.verify(pk, signing_bytes(rec), sig)
  end

  defp signature_ok?(_), do: false

  defp grant_window?(%__MODULE__{} = rec, now) do
    rec.issued_at <= now + @issued_skew_s and rec.expires_at > now and
      rec.expires_at - rec.issued_at <= @max_lifetime
  end
end
