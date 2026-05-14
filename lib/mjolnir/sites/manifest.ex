defmodule Mjolnir.Sites.Manifest do
  @moduledoc """
  Snapshot manifest type and (de)serialization.

  See `docs/plans/initiatives/identikey-sites.md` §5 for the full schema.

  ## Shape

      %Manifest{
        version: 1,
        identikey_fp: "...",
        site_name: "blog",
        mode: :public,            # | :gated | :group
        created_at: ~U[...],
        sym_seed: <<32 bytes>>,   # public mode only; nil otherwise
        entries: [%Entry{}],
        signatures: <signature blob>
      }

  Entries describe individual files:

      %Entry{
        path: "/index.html",
        content_type: "text/html; charset=utf-8",
        bao_hash: "...",
        ciphertext_size: 12345,
        plaintext_size: 12000,
        nonce: <<24 bytes>>,
        wrapped_key: nil,          # public mode; bytes for gated/group
        content_encoding: nil      # "gzip" | "br" | nil
      }

  ## Wire format

  Phase 1 uses JSON for the canonical body (with base64-encoded binary fields).
  Recrypt's actual wire format is Gordian Envelope / dCBOR — the seam is
  `serialize/1` and `parse/1`, which can be swapped to envelope-based
  serialization without changing callers. For now keep JSON for fast iteration.
  """

  defmodule Entry do
    @moduledoc false
    defstruct [
      :path,
      :content_type,
      :bao_hash,
      :ciphertext_size,
      :plaintext_size,
      :nonce,
      :wrapped_key,
      :content_encoding
    ]

    @type t :: %__MODULE__{
            path: String.t(),
            content_type: String.t(),
            bao_hash: String.t(),
            ciphertext_size: non_neg_integer(),
            plaintext_size: non_neg_integer(),
            nonce: binary(),
            wrapped_key: binary() | nil,
            content_encoding: String.t() | nil
          }
  end

  defstruct [
    :version,
    :identikey_fp,
    :site_name,
    :mode,
    :created_at,
    :sym_seed,
    :entries,
    :signatures
  ]

  @type mode :: :public | :gated | :group

  @type t :: %__MODULE__{
          version: pos_integer(),
          identikey_fp: String.t(),
          site_name: String.t(),
          mode: mode(),
          created_at: DateTime.t(),
          sym_seed: binary() | nil,
          entries: [Entry.t()],
          signatures: binary() | nil
        }

  @doc "Find an entry by path. Returns `nil` if not present."
  @spec lookup_entry(t(), String.t()) :: Entry.t() | nil
  def lookup_entry(%__MODULE__{entries: entries}, path) do
    Enum.find(entries, &(&1.path == path))
  end

  @doc """
  Serialize a manifest to canonical bytes. The bytes returned are what the
  IdentiKey signs, and what gets hashed to derive the snapshot hash.
  """
  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = m) do
    %{
      "version" => m.version,
      "identikey_fp" => m.identikey_fp,
      "site_name" => m.site_name,
      "mode" => Atom.to_string(m.mode),
      "created_at" => DateTime.to_iso8601(m.created_at),
      "sym_seed" => encode_bin(m.sym_seed),
      "entries" => Enum.map(m.entries, &entry_to_map/1),
      "signatures" => encode_bin(m.signatures)
    }
    |> Jason.encode!()
  end

  @doc "Parse manifest bytes back to a struct."
  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, raw} ->
        try do
          {:ok,
           %__MODULE__{
             version: Map.fetch!(raw, "version"),
             identikey_fp: Map.fetch!(raw, "identikey_fp"),
             site_name: Map.fetch!(raw, "site_name"),
             mode: String.to_existing_atom(Map.fetch!(raw, "mode")),
             created_at: parse_dt!(Map.fetch!(raw, "created_at")),
             sym_seed: decode_bin(Map.get(raw, "sym_seed")),
             entries:
               raw
               |> Map.fetch!("entries")
               |> Enum.map(&entry_from_map/1),
             signatures: decode_bin(Map.get(raw, "signatures"))
           }}
        rescue
          e -> {:error, {:bad_manifest, e}}
        end

      {:error, decode_error} ->
        {:error, {:bad_manifest, decode_error}}
    end
  end

  @doc """
  Return the canonical bytes that are signed over. Identical to `serialize/1`
  but with the `signatures` field set to `nil` (excluded from the JSON value).
  This avoids the chicken-and-egg problem where the signature must be computed
  before the final serialized form is known.
  """
  @spec canonical_signing_bytes(t()) :: binary()
  def canonical_signing_bytes(%__MODULE__{} = m) do
    serialize(%{m | signatures: nil})
  end

  @doc """
  Compute the snapshot hash from serialized manifest bytes. Returns the
  base58-encoded Blake3 hash that identifies this snapshot. Delegates to
  `Mjolnir.Sites.Crypto.blake3_hash_base58/1` so callers don't need to know
  which implementation is plugged in underneath.
  """
  @spec snapshot_hash(binary()) :: String.t()
  def snapshot_hash(serialized) when is_binary(serialized) do
    Mjolnir.Sites.Crypto.blake3_hash_base58(serialized)
  end

  ## Internals

  defp entry_to_map(%Entry{} = e) do
    %{
      "path" => e.path,
      "content_type" => e.content_type,
      "bao_hash" => e.bao_hash,
      "ciphertext_size" => e.ciphertext_size,
      "plaintext_size" => e.plaintext_size,
      "nonce" => encode_bin(e.nonce),
      "wrapped_key" => encode_bin(e.wrapped_key),
      "content_encoding" => e.content_encoding
    }
  end

  defp entry_from_map(raw) do
    %Entry{
      path: Map.fetch!(raw, "path"),
      content_type: Map.fetch!(raw, "content_type"),
      bao_hash: Map.fetch!(raw, "bao_hash"),
      ciphertext_size: Map.fetch!(raw, "ciphertext_size"),
      plaintext_size: Map.fetch!(raw, "plaintext_size"),
      nonce: decode_bin(Map.fetch!(raw, "nonce")),
      wrapped_key: decode_bin(Map.get(raw, "wrapped_key")),
      content_encoding: Map.get(raw, "content_encoding")
    }
  end

  defp encode_bin(nil), do: nil
  defp encode_bin(bin) when is_binary(bin), do: Base.encode64(bin)

  defp decode_bin(nil), do: nil

  defp decode_bin(str) when is_binary(str) do
    case Base.decode64(str) do
      {:ok, bin} -> bin
      :error -> nil
    end
  end

  defp parse_dt!(str) do
    {:ok, dt, _} = DateTime.from_iso8601(str)
    dt
  end

end
