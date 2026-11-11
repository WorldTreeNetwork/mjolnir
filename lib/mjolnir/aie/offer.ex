defmodule Mjolnir.Aie.Offer do
  @moduledoc """
  Signed AIE offer leaf in the owner's SecretStore keyspace.

  Canonical execute resource is `{owner_fp, offer_id}` plus `incarnation`
  (Blake3 of the canonical signed leaf bytes). Sequence is strictly
  increasing; a tombstone at the same key is the floor. v1 revocation is
  whole-offer replacement.

  `owner_fp` is `IdentiKey.fingerprint/1` (keyspace path). `being_pubkey`
  is the being's 32-byte Ed25519 key so execute can derive auth-challenge
  v1 §5 holder fp. The two namespaces are not interchangeable.

  `VM.spawn/1` does not create this record.
  """

  alias Mjolnir.Aie.Allowlist
  alias Mjolnir.SecretStore
  alias Mjolnir.Sites.{Crypto, IdentiKey, MultiSig}

  defstruct [
    :owner_fp,
    :offer_id,
    :vm_id,
    :being_pubkey,
    :sequence,
    :guild,
    :design_ids,
    :max_wall_time,
    :tombstone,
    :signature,
    version: 1
  ]

  @type t :: %__MODULE__{
          version: pos_integer(),
          owner_fp: String.t(),
          offer_id: String.t(),
          vm_id: String.t(),
          being_pubkey: binary(),
          sequence: pos_integer(),
          guild: String.t() | nil,
          design_ids: [String.t()],
          max_wall_time: pos_integer(),
          tombstone: boolean(),
          signature: binary() | nil
        }

  @key_prefix "aie/offers/"

  @doc "SecretStore key for a local `offer_id` under the owner's keyspace."
  @spec key(String.t()) :: String.t()
  def key(offer_id) when is_binary(offer_id) do
    if offer_id == "" or String.contains?(offer_id, ["/", "\\", "\0", ".."]) do
      raise ArgumentError, "invalid offer_id: #{inspect(offer_id)}"
    else
      @key_prefix <> offer_id
    end
  end

  @spec key_prefix() :: String.t()
  def key_prefix, do: @key_prefix

  @spec offer_key?(String.t()) :: boolean()
  def offer_key?(key) when is_binary(key), do: String.starts_with?(key, @key_prefix)

  @doc "Serialize an offer leaf to canonical JSON bytes."
  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = r) do
    %{
      "version" => r.version,
      "owner_fp" => r.owner_fp,
      "offer_id" => r.offer_id,
      "vm_id" => r.vm_id,
      "being_pubkey" => Base.encode64(r.being_pubkey),
      "sequence" => r.sequence,
      "guild" => r.guild,
      "design_ids" => r.design_ids || [],
      "max_wall_time" => r.max_wall_time,
      "tombstone" => r.tombstone || false,
      "signature" => encode_sig(r.signature)
    }
    |> Jason.encode!()
  end

  @spec canonical_signing_bytes(t()) :: binary()
  def canonical_signing_bytes(%__MODULE__{} = r) do
    serialize(%{r | signature: nil})
  end

  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, raw} ->
        try do
          pubkey = decode_pubkey!(Map.fetch!(raw, "being_pubkey"))

          {:ok,
           %__MODULE__{
             version: Map.fetch!(raw, "version"),
             owner_fp: Map.fetch!(raw, "owner_fp"),
             offer_id: Map.fetch!(raw, "offer_id"),
             vm_id: Map.fetch!(raw, "vm_id"),
             being_pubkey: pubkey,
             sequence: Map.fetch!(raw, "sequence"),
             guild: Map.get(raw, "guild"),
             design_ids: Map.get(raw, "design_ids", []),
             max_wall_time: Map.fetch!(raw, "max_wall_time"),
             tombstone: Map.get(raw, "tombstone", false) == true,
             signature: decode_sig(Map.get(raw, "signature"))
           }}
        rescue
          e -> {:error, {:bad_offer_record, e}}
        end

      {:error, decode_error} ->
        {:error, {:bad_offer_record, decode_error}}
    end
  end

  @doc "Blake3 (base58) of canonical signed leaf bytes."
  @spec incarnation(t() | binary()) :: String.t()
  def incarnation(%__MODULE__{} = offer), do: incarnation(serialize(offer))

  def incarnation(bytes) when is_binary(bytes) do
    Crypto.blake3_hash_base58(bytes)
  end

  @spec sign(t(), IdentiKey.keypair()) :: t()
  def sign(%__MODULE__{} = offer, keypair) do
    sig = IdentiKey.sign(keypair, canonical_signing_bytes(offer))
    %{offer | signature: sig}
  end

  @doc """
  Publish a signed offer leaf. Requires the named VM's IdentiKey to equal
  `owner_fp` and that VM id to be on the host offering allowlist.
  """
  @spec publish(t(), IdentiKey.keypair()) :: :ok | {:error, term()}
  def publish(%__MODULE__{} = offer, keypair) do
    signed = sign(offer, keypair)

    with :ok <- gate_offering(signed) do
      SecretStore.put(signed.owner_fp, key(signed.offer_id), serialize(signed))
    end
  end

  @doc "Replace the current leaf with a signed tombstone (sequence floor)."
  @spec withdraw(String.t(), String.t(), IdentiKey.keypair()) :: :ok | {:error, term()}
  def withdraw(owner_fp, offer_id, keypair)
      when is_binary(owner_fp) and is_binary(offer_id) do
    with {:ok, current, _bytes} <- fetch_verified(owner_fp, offer_id),
         tombstone =
           sign(
             %{current | tombstone: true, sequence: current.sequence + 1, signature: nil},
             keypair
           ),
         :ok <- gate_offering(tombstone) do
      SecretStore.put(owner_fp, key(offer_id), serialize(tombstone))
    end
  end

  @doc """
  Copy incarnation from the current verified live leaf. Does not mint Biscuit
  bytes; that crypto stays on the host mint root.
  """
  @spec mint(String.t(), String.t()) ::
          {:ok, %{owner_fp: String.t(), offer_id: String.t(), incarnation: String.t()}}
          | {:error, term()}
  def mint(owner_fp, offer_id) when is_binary(owner_fp) and is_binary(offer_id) do
    with {:ok, offer, bytes} <- fetch_verified(owner_fp, offer_id),
         :ok <- live(offer),
         :ok <- gate_offering(offer) do
      {:ok,
       %{
         owner_fp: offer.owner_fp,
         offer_id: offer.offer_id,
         incarnation: incarnation(bytes)
       }}
    end
  end

  @doc """
  Authorize execute against a named `{owner_fp, offer_id, incarnation}`.
  Missing, unsigned, tombstoned, other-being, allowlist, or incarnation
  mismatch refuses.
  """
  @spec authorize_execute(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def authorize_execute(owner_fp, offer_id, incarnation)
      when is_binary(owner_fp) and is_binary(offer_id) and is_binary(incarnation) do
    with {:ok, offer, bytes} <- fetch_verified(owner_fp, offer_id),
         :ok <- live(offer),
         :ok <- gate_offering(offer),
         true <- incarnation(bytes) == incarnation do
      :ok
    else
      :not_found -> {:error, :not_found}
      false -> {:error, :incarnation_mismatch}
      {:error, _} = err -> err
    end
  end

  @spec fetch(String.t(), String.t()) :: {:ok, t(), binary()} | :not_found | {:error, term()}
  def fetch(owner_fp, offer_id) when is_binary(owner_fp) and is_binary(offer_id) do
    fetch_verified(owner_fp, offer_id)
  end

  @spec exists?(String.t(), String.t()) :: boolean()
  def exists?(owner_fp, offer_id) do
    match?({:ok, _, _}, fetch_verified(owner_fp, offer_id))
  end

  ## Internals

  defp fetch_verified(owner_fp, offer_id) do
    case SecretStore.get(owner_fp, key(offer_id)) do
      :not_found ->
        :not_found

      {:error, _} = err ->
        err

      {:ok, bytes} ->
        with :ok <- SecretStore.verify_envelope(owner_fp, bytes),
             {:ok, offer} <- parse(bytes),
             true <- offer.owner_fp == owner_fp do
          {:ok, offer, bytes}
        else
          false -> {:error, :owner_mismatch}
          {:error, _} = err -> err
        end
    end
  end

  defp live(%__MODULE__{tombstone: true}), do: {:error, :tombstoned}
  defp live(%__MODULE__{}), do: :ok

  defp gate_offering(%__MODULE__{} = offer) do
    cond do
      not is_binary(offer.being_pubkey) or byte_size(offer.being_pubkey) != 32 ->
        {:error, :bad_being_pubkey}

      IdentiKey.fingerprint(offer.being_pubkey) != offer.owner_fp ->
        {:error, :being_mismatch}

      not Allowlist.member?(offer.vm_id) ->
        {:error, :not_allowlisted}

      true ->
        case Allowlist.identikey_for(offer.vm_id) do
          {:ok, fp} when fp == offer.owner_fp -> :ok
          {:ok, _} -> {:error, :unrelated_vm}
          {:error, _} = err -> err
        end
    end
  end

  defp decode_pubkey!(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, pub} when byte_size(pub) == 32 -> pub
      {:ok, _} -> raise ArgumentError, "being_pubkey must be 32 bytes"
      :error -> raise ArgumentError, "being_pubkey is not base64"
    end
  end

  defp encode_sig(nil), do: nil
  defp encode_sig(<<>>), do: nil

  defp encode_sig(bin) when is_binary(bin) do
    MultiSig.to_field(%MultiSig{ed25519: bin})
  end

  defp encode_sig(%MultiSig{} = ms), do: MultiSig.to_field(ms)

  defp decode_sig(field) do
    case MultiSig.from_field(field) do
      nil -> nil
      %MultiSig{ed25519: ed} -> ed
    end
  end
end
