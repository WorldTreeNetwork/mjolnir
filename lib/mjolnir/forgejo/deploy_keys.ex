defmodule Mjolnir.Forgejo.DeployKeys do
  @moduledoc """
  Host-side Forgejo repo deploy-key client.

  Registers and deletes the hosted being's `ssh_git` pubkey as a **write**
  deploy key on `VirtueInnova/hypersigil-store-frontend`. The guest never
  sees the Forgejo token; it authenticates `git` with
  `/run/mjolnir/git_signing_key` only.

  Token comes from `Application.get_env(:mjolnir, :forgejo_token)` (runtime:
  `MJOLNIR_FORGEJO_TOKEN`). Do not log it. No token is `:not_wired` — the
  reconcile find for dev/test, not a fake delete.
  """

  @default_owner "VirtueInnova"
  @default_repo "hypersigil-store-frontend"
  @default_url "http://127.0.0.1:3000"

  @type meta :: map()
  @type key_id :: pos_integer() | String.t()

  @doc """
  Create a write deploy key. Title includes `vm_id` (and `xid` if known).

  Returns `{:ok, key_id}`, `:not_wired` when no token, or `{:error, reason}`.
  """
  @spec register(meta()) :: {:ok, key_id()} | :not_wired | {:error, term()}
  def register(meta) when is_map(meta) do
    pubkey = meta_get(meta, "public_key")
    vm_id = meta_get(meta, "vm_id")
    xid = meta_get(meta, "xid")

    cond do
      not usable_string?(pubkey) ->
        {:error, :missing_public_key}

      not usable_string?(vm_id) ->
        {:error, :missing_vm_id}

      true ->
        with {:ok, creds} <- credentials() do
          create_or_find(creds, pubkey, title(vm_id, xid))
        end
    end
  end

  @doc """
  Delete the deploy key named by `forgejo_key_id` or matching `public_key`.

  404 is success (already gone). Transport / HTTP errors are `{:error, …}` —
  never mapped to `:ok`. No token is `:not_wired`.
  """
  @spec revoke(meta()) :: :ok | :not_wired | {:error, term()}
  def revoke(meta) when is_map(meta) do
    with {:ok, creds} <- credentials() do
      do_revoke(creds, meta)
    end
  end

  @doc false
  @spec credentials() :: {:ok, map()} | :not_wired
  def credentials do
    case token() do
      nil -> :not_wired
      tok -> {:ok, %{url: base_url(), token: tok, owner: owner(), repo: repo()}}
    end
  end

  defp do_revoke(creds, meta) do
    key_id = meta_get(meta, "forgejo_key_id")
    pubkey = meta_get(meta, "public_key")

    cond do
      present_id?(key_id) ->
        delete_id(creds, key_id)

      usable_string?(pubkey) ->
        delete_by_pubkey(creds, pubkey)

      true ->
        :ok
    end
  end

  defp create_or_find(creds, pubkey, title) do
    body = %{
      "title" => title,
      "key" => String.trim(pubkey),
      "read_only" => false
    }

    case request(creds, :post, keys_path(creds), body) do
      {:ok, status, resp} when status in [200, 201] ->
        fetch_id(resp)

      {:ok, 422, _} ->
        find_id(creds, pubkey)

      {:ok, status, resp} ->
        {:error, {:http_status, status, safe_body(resp)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_id(creds, pubkey) do
    case list_keys(creds) do
      {:ok, keys} ->
        blob = key_blob(pubkey)

        case Enum.find(keys, fn k -> key_blob(k["key"] || "") == blob end) do
          %{"id" => id} -> {:ok, id}
          nil -> {:error, :key_not_listed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_by_pubkey(creds, pubkey) do
    case list_keys(creds) do
      {:ok, keys} ->
        blob = key_blob(pubkey)

        case Enum.find(keys, fn k -> key_blob(k["key"] || "") == blob end) do
          %{"id" => id} -> delete_id(creds, id)
          nil -> :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_id(creds, key_id) do
    with {:ok, id_s} <- id_segment(key_id) do
      case request(creds, :delete, keys_path(creds) <> "/" <> id_s, nil) do
        {:ok, status, _} when status in [200, 204, 404] -> :ok
        {:ok, status, resp} -> {:error, {:http_status, status, safe_body(resp)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp list_keys(creds) do
    case request(creds, :get, keys_path(creds), nil) do
      {:ok, 200, keys} when is_list(keys) -> {:ok, keys}
      {:ok, status, resp} -> {:error, {:http_status, status, safe_body(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(creds, method, path, body) do
    url = creds.url <> path
    headers = [{"authorization", "token " <> creds.token}, {"accept", "application/json"}]

    case http_fun() do
      fun when is_function(fun, 4) ->
        normalize_http(fun.(method, url, headers, body))

      _ ->
        req_http(method, url, headers, body)
    end
  end

  defp req_http(method, url, headers, body) do
    opts = [headers: headers, retry: false, receive_timeout: 15_000, decode_body: true]
    opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)

    result =
      case method do
        :get -> Req.get(url, opts)
        :post -> Req.post(url, opts)
        :delete -> Req.delete(url, opts)
      end

    case result do
      {:ok, %Req.Response{status: status, body: resp}} ->
        {:ok, status, resp}

      {:error, exception} ->
        {:error, {:http_error, req_error_reason(exception)}}
    end
  end

  defp normalize_http({:ok, status, body}) when is_integer(status), do: {:ok, status, body}
  defp normalize_http({:error, reason}), do: {:error, reason}
  defp normalize_http(other), do: {:error, {:unexpected_http_result, other}}

  defp req_error_reason(%_{} = e), do: e.__struct__
  defp req_error_reason(other) when is_atom(other), do: other
  defp req_error_reason(_), do: :transport

  defp fetch_id(%{"id" => id}) when is_integer(id) and id > 0, do: {:ok, id}
  defp fetch_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  defp fetch_id(_), do: {:error, :missing_key_id}

  defp id_segment(id) when is_integer(id) and id > 0, do: {:ok, Integer.to_string(id)}

  defp id_segment(id) when is_binary(id) do
    if Regex.match?(~r/^\d+$/, id), do: {:ok, id}, else: {:error, :invalid_key_id}
  end

  defp id_segment(_), do: {:error, :invalid_key_id}

  defp present_id?(id) when is_integer(id) and id > 0, do: true
  defp present_id?(id) when is_binary(id), do: Regex.match?(~r/^\d+$/, id)
  defp present_id?(_), do: false

  defp title(vm_id, xid) do
    base = "mjolnir ssh_git #{vm_id}"

    if usable_string?(xid) do
      base <> " xid=#{xid}"
    else
      base
    end
  end

  defp key_blob(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.split()
    |> Enum.take(2)
    |> Enum.join(" ")
  end

  defp key_blob(_), do: ""

  defp keys_path(%{owner: owner, repo: repo}) do
    "/api/v1/repos/#{URI.encode(owner)}/#{URI.encode(repo)}/keys"
  end

  defp token do
    case Application.get_env(:mjolnir, :forgejo_token) do
      t when is_binary(t) and t != "" -> t
      _ -> nil
    end
  end

  defp base_url do
    url =
      Application.get_env(:mjolnir, :forgejo_url) ||
        Application.get_env(:mjolnir, :runner_forgejo_url) ||
        @default_url

    url |> to_string() |> String.trim_trailing("/")
  end

  defp owner do
    case Application.get_env(:mjolnir, :forgejo_deploy_owner, @default_owner) do
      o when is_binary(o) and o != "" -> o
      _ -> @default_owner
    end
  end

  defp repo do
    case Application.get_env(:mjolnir, :forgejo_deploy_repo, @default_repo) do
      r when is_binary(r) and r != "" -> r
      _ -> @default_repo
    end
  end

  defp http_fun, do: Application.get_env(:mjolnir, :forgejo_http)

  defp meta_get(meta, "public_key"), do: Map.get(meta, "public_key") || Map.get(meta, :public_key)
  defp meta_get(meta, "vm_id"), do: Map.get(meta, "vm_id") || Map.get(meta, :vm_id)
  defp meta_get(meta, "xid"), do: Map.get(meta, "xid") || Map.get(meta, :xid)

  defp meta_get(meta, "forgejo_key_id"),
    do: Map.get(meta, "forgejo_key_id") || Map.get(meta, :forgejo_key_id)

  defp usable_string?(s) when is_binary(s), do: String.trim(s) != ""
  defp usable_string?(_), do: false

  defp safe_body(body) when is_map(body) do
    Map.take(body, ["message", "error", "errors", "id", "url"])
  end

  defp safe_body(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp safe_body(body) when is_list(body), do: %{count: length(body)}
  defp safe_body(_), do: :unprintable
end
