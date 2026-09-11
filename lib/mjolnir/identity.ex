defmodule Mjolnir.Identity do
  @moduledoc """
  Opaque Buzz-agent identity (nsec + relay URL).

  The nsec is a string we never interpret (no curve math). It lives in
  `Mjolnir.SecretStore` under `_opaque/vms/<vm_id>/`, is injected over
  vsock into `/run/mjolnir/buzz.env`, and is never kept on the VM struct
  or written to StateStore / API views / host logs.

  See `openspec/changes/add-buzz-local-runtime` (mjolnir-1pe).
  """

  @type t :: %{
          private_key_nsec: String.t(),
          relay_url: String.t(),
          auth_tag: String.t() | nil,
          env: %{optional(String.t()) => String.t()}
        }

  @opaque_key "identity"
  @store_kind "vms"

  @doc """
  Parse an API/spawn identity object.

  Returns `:absent` when the field is missing, `{:ok, identity}` when both
  strings are present and clean, or `{:error, message}` for a bad shape.
  """
  @spec parse_params(term()) :: :absent | {:ok, t()} | {:error, String.t()}
  def parse_params(nil), do: :absent

  def parse_params(params) when is_map(params) do
    nsec = Map.get(params, "private_key_nsec") || Map.get(params, :private_key_nsec)
    url = Map.get(params, "relay_url") || Map.get(params, :relay_url)
    auth_tag = optional_string(params, "auth_tag")
    env = optional_env(params)

    cond do
      not is_binary(nsec) or not is_binary(url) ->
        {:error, "identity must include private_key_nsec and relay_url strings"}

      nsec == "" or url == "" ->
        {:error, "identity.private_key_nsec and identity.relay_url must be non-empty"}

      not clean_string?(nsec) or not clean_string?(url) ->
        {:error, "identity values must not contain control characters"}

      match?({:error, _}, auth_tag) ->
        auth_tag

      match?({:error, _}, env) ->
        env

      true ->
        {:ok,
         %{
           private_key_nsec: nsec,
           relay_url: url,
           auth_tag: elem(auth_tag, 1),
           env: elem(env, 1)
         }}
    end
  end

  def parse_params(_), do: {:error, "identity must be a JSON object"}

  @doc "Persist identity for `vm_id`. Overwrites. Never logs the bytes."
  @spec put(String.t(), t()) :: :ok | {:error, term()}
  def put(vm_id, %{private_key_nsec: nsec, relay_url: url} = identity)
      when is_binary(nsec) and is_binary(url) do
    case parse_params(identity) do
      {:ok, clean} ->
        Mjolnir.SecretStore.put_opaque(@store_kind, vm_id, @opaque_key, Jason.encode!(clean))

      {:error, _} = err ->
        err

      :absent ->
        {:error, :invalid_identity}
    end
  end

  def put(_, _), do: {:error, :invalid_identity}

  @doc "Read the stored identity. `:not_found` if none."
  @spec get(String.t()) :: {:ok, t()} | :not_found | {:error, term()}
  def get(vm_id) do
    case Mjolnir.SecretStore.get_opaque(@store_kind, vm_id, @opaque_key) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, map} -> parse_params(map)
          {:error, reason} -> {:error, {:invalid_stored_identity, reason}}
        end

      other ->
        other
    end
  end

  @doc "Remove stored identity. Idempotent."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(vm_id), do: Mjolnir.SecretStore.delete_opaque(@store_kind, vm_id, @opaque_key)

  @doc "True when SecretStore holds an identity for this VM."
  @spec stored?(String.t()) :: boolean()
  def stored?(vm_id) do
    match?({:ok, _}, get(vm_id))
  end

  @doc """
  Env entries the guest writes to `/run/mjolnir/buzz.env`.

  Keys only — callers that log should use `entry_keys/1`, not this map.
  """
  @spec env_entries(t()) :: %{String.t() => String.t()}
  def env_entries(%{private_key_nsec: nsec, relay_url: url} = identity) do
    base = %{
      "BUZZ_PRIVATE_KEY" => nsec,
      "NOSTR_PRIVATE_KEY" => nsec,
      "BUZZ_RELAY_URL" => url
    }

    base =
      case identity[:auth_tag] || identity["auth_tag"] do
        tag when is_binary(tag) and tag != "" -> Map.put(base, "BUZZ_AUTH_TAG", tag)
        _ -> base
      end

    extra = identity[:env] || identity["env"] || %{}
    # Extra env must not clobber identity keys. Those come from the top-level
    # payload, never from a nested map (Buzz reserved-key rule).
    Map.merge(base, Map.drop(extra, Map.keys(base)))
  end

  @doc "Key names only, for logs."
  @spec entry_keys(t()) :: [String.t()]
  def entry_keys(identity), do: identity |> env_entries() |> Map.keys() |> Enum.sort()

  @doc """
  True when `blob` (any inspectable term, or a binary) contains the nsec.

  Used by the negative host-artifact test. Does not search SecretStore.
  """
  @spec leaked_in?(String.t(), term()) :: boolean()
  def leaked_in?(nsec, blob) when is_binary(nsec) and nsec != "" do
    blob
    |> artifact_text()
    |> String.contains?(nsec)
  end

  def leaked_in?(_, _), do: false

  defp clean_string?(s) do
    not String.contains?(s, ["\0", "\n", "\r"])
  end

  defp optional_string(params, name) do
    atom = extra_atom(name)

    case Map.get(params, name) || (atom && Map.get(params, atom)) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      value when is_binary(value) ->
        if clean_string?(value) do
          {:ok, value}
        else
          {:error, "identity.#{name} must not contain control characters"}
        end

      _ ->
        {:error, "identity.#{name} must be a string"}
    end
  end

  defp extra_atom("auth_tag"), do: :auth_tag
  defp extra_atom(_), do: nil

  defp optional_env(params) do
    case Map.get(params, "env") || Map.get(params, :env) do
      nil ->
        {:ok, %{}}

      env when is_map(env) ->
        Enum.reduce_while(env, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
          key = to_string(k)

          cond do
            not is_binary(v) ->
              {:halt, {:error, "identity.env values must be strings"}}

            not posix_env_name?(key) ->
              {:halt, {:error, "identity.env key #{inspect(key)} is not a POSIX env name"}}

            not clean_string?(v) or String.contains?(v, "\t") ->
              {:halt, {:error, "identity.env #{key} must not contain control characters"}}

            true ->
              {:cont, {:ok, Map.put(acc, key, v)}}
          end
        end)

      _ ->
        {:error, "identity.env must be an object"}
    end
  end

  defp posix_env_name?(key) do
    key != "" and not String.match?(key, ~r/^[0-9]/) and String.match?(key, ~r/\A[A-Za-z0-9_]+\z/)
  end

  defp artifact_text(blob) when is_binary(blob), do: blob
  defp artifact_text(blob), do: inspect(blob, limit: :infinity, printable_limit: :infinity)
end
