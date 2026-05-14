defmodule Mjolnir.Sites.AliasRecord do
  @moduledoc """
  Custom-domain alias record for a site. Lives in the SecretStore under
  `(identikey_fp, "sites/<site_name>/aliases/<fqdn>")`.

  See `docs/plans/initiatives/identikey-sites.md` for the design context.

      %AliasRecord{
        version: 1,
        identikey_fp: "...",
        site_name: "blog",
        fqdn: "blog.duke.io",
        sequence: 1,           # monotonic; higher wins on conflict
        created_at: ~U[...],
        signature: <bytes>
      }

  Wire format: JSON, with base64-encoded signature.
  """

  defstruct [
    :version,
    :identikey_fp,
    :site_name,
    :fqdn,
    :sequence,
    :created_at,
    :signature
  ]

  @type t :: %__MODULE__{
          version: pos_integer(),
          identikey_fp: String.t(),
          site_name: String.t(),
          fqdn: String.t(),
          sequence: non_neg_integer(),
          created_at: DateTime.t(),
          signature: binary() | nil
        }

  @doc "Serialize an alias record to canonical bytes."
  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = r) do
    %{
      "version" => r.version,
      "identikey_fp" => r.identikey_fp,
      "site_name" => r.site_name,
      "fqdn" => r.fqdn,
      "sequence" => r.sequence,
      "created_at" => DateTime.to_iso8601(r.created_at),
      "signature" => if(r.signature, do: Base.encode64(r.signature), else: nil)
    }
    |> Jason.encode!()
  end

  @doc """
  Return the canonical bytes that are signed over. Identical to `serialize/1`
  but with the `signature` field set to `nil` (excluded from the JSON value).
  """
  @spec canonical_signing_bytes(t()) :: binary()
  def canonical_signing_bytes(%__MODULE__{} = r) do
    serialize(%{r | signature: nil})
  end

  @doc "Parse alias record bytes."
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
             fqdn: Map.fetch!(raw, "fqdn"),
             sequence: Map.fetch!(raw, "sequence"),
             created_at: parse_dt!(Map.fetch!(raw, "created_at")),
             signature: decode_sig(Map.get(raw, "signature"))
           }}
        rescue
          e -> {:error, {:bad_alias_record, e}}
        end

      {:error, decode_error} ->
        {:error, {:bad_alias_record, decode_error}}
    end
  end

  @doc """
  Returns true if `candidate` should replace `current` based on sequence
  ordering (and a deterministic tie-break by fqdn when sequences are equal).
  """
  @spec replaces?(t(), t()) :: boolean()
  def replaces?(%__MODULE__{} = candidate, %__MODULE__{} = current) do
    cond do
      candidate.sequence > current.sequence -> true
      candidate.sequence < current.sequence -> false
      true -> candidate.fqdn > current.fqdn
    end
  end

  ## Internals

  defp parse_dt!(str) do
    {:ok, dt, _} = DateTime.from_iso8601(str)
    dt
  end

  defp decode_sig(nil), do: nil

  defp decode_sig(str) when is_binary(str) do
    case Base.decode64(str) do
      {:ok, bin} -> bin
      :error -> nil
    end
  end
end
