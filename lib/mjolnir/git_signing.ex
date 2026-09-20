defmodule Mjolnir.GitSigning do
  @moduledoc """
  Opaque SSH git-signing key for a hosted being.

  Private material lives in SecretStore `_opaque/vms/<id>/git_signing`
  and is injected to `/run/mjolnir/git_signing_key`. Never on the VM
  struct, StateStore, or API views.

  Device metadata (`xid`, identikey `credential_id`, public key) is a
  separate opaque blob (`git_signing_device`) so respawn can revoke
  without copying private bytes across `vm_id`s.
  """

  @store_kind "vms"
  @opaque_key "git_signing"
  @device_key "git_signing_device"
  @guest_name "git_signing_key"

  @type device_meta :: %{
          optional(:xid) => String.t(),
          optional(:credential_id) => String.t(),
          optional(:public_key) => String.t()
        }

  @doc "Persist an OpenSSH private key for `vm_id`."
  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(vm_id, pem) when is_binary(vm_id) and is_binary(pem) and pem != "" do
    Mjolnir.SecretStore.put_opaque(@store_kind, vm_id, @opaque_key, pem)
  end

  @spec get(String.t()) :: {:ok, binary()} | :not_found | {:error, term()}
  def get(vm_id), do: Mjolnir.SecretStore.get_opaque(@store_kind, vm_id, @opaque_key)

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(vm_id) do
    with :ok <- Mjolnir.SecretStore.delete_opaque(@store_kind, vm_id, @opaque_key) do
      Mjolnir.SecretStore.delete_opaque(@store_kind, vm_id, @device_key)
    end
  end

  @doc "Mint an ed25519 OpenSSH keypair. Returns `{private, public}`."
  @spec generate() :: {:ok, {binary(), binary()}} | {:error, term()}
  def generate do
    dir = Path.join(System.tmp_dir!(), "mj-git-signing-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(dir),
         path = Path.join(dir, "id_ed25519"),
         {_, 0} <-
           System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-f", path, "-q"],
             stderr_to_stdout: true
           ),
         {:ok, priv} <- File.read(path),
         {:ok, pub} <- File.read(path <> ".pub") do
      _ = File.rm_rf(dir)
      {:ok, {priv, pub}}
    else
      {out, status} ->
        _ = File.rm_rf(dir)
        {:error, {:ssh_keygen, status, out}}

      {:error, reason} ->
        _ = File.rm_rf(dir)
        {:error, reason}
    end
  end

  @doc """
  Mint a new keypair for `vm_id` and store the private opaque.

  Never reads another VM's opaque. Returns the public key (not stored
  on the VM struct).
  """
  @spec mint(String.t()) :: {:ok, binary()} | {:error, term()}
  def mint(vm_id) when is_binary(vm_id) do
    with {:ok, {priv, pub}} <- generate(),
         :ok <- put(vm_id, priv),
         :ok <- put_device(vm_id, %{public_key: String.trim(pub)}) do
      {:ok, pub}
    end
  end

  @doc """
  Persist identikey device metadata. Refuses private key material.
  """
  @spec put_device(String.t(), map()) :: :ok | {:error, term()}
  def put_device(vm_id, meta) when is_binary(vm_id) and is_map(meta) do
    if private_in_meta?(meta) do
      {:error, :private_key_not_on_device_meta}
    else
      payload =
        %{}
        |> maybe_put_meta("public_key", meta)
        |> maybe_put_meta("xid", meta)
        |> maybe_put_meta("credential_id", meta)

      Mjolnir.SecretStore.put_opaque(@store_kind, vm_id, @device_key, Jason.encode!(payload))
    end
  end

  @spec get_device(String.t()) :: {:ok, map()} | :not_found | {:error, term()}
  def get_device(vm_id) do
    case Mjolnir.SecretStore.get_opaque(@store_kind, vm_id, @device_key) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, map} -> {:ok, map}
          {:error, reason} -> {:error, {:invalid_device_meta, reason}}
        end

      other ->
        other
    end
  end

  @doc """
  Retire a hosted git-signing device.

  Order is Forgejo key delete (`add-honor-git-remote`, currently a
  `:not_wired` find), then identikey `revoke_device`, then opaque
  delete. A crash after identikey revoke must not happen before it —
  if `revoke_device` fails the private blob stays so we never leave a
  live key with no identikey row. Forgejo not being wired is the
  reconcile find, not a fake delete.
  """
  @spec revoke(String.t()) :: :ok | {:error, term()}
  def revoke(vm_id) when is_binary(vm_id) do
    case get_device(vm_id) do
      {:error, reason} -> {:error, reason}
      :not_found -> finish_revoke(vm_id, %{})
      {:ok, map} -> finish_revoke(vm_id, map)
    end
  end

  defp finish_revoke(vm_id, meta) do
    with :ok <- forgejo_revoke(meta),
         :ok <- identikey_revoke_device(meta),
         :ok <- delete(vm_id) do
      :ok
    end
  end

  @doc """
  New `vm_id` gets a new keypair; the old device is revoked.

  Does not copy `_opaque` across ids.
  """
  @spec respawn(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def respawn(old_vm_id, new_vm_id)
      when is_binary(old_vm_id) and is_binary(new_vm_id) and old_vm_id != new_vm_id do
    with {:ok, pub} <- mint(new_vm_id),
         :ok <- revoke(old_vm_id) do
      {:ok, pub}
    end
  end

  def respawn(same, same) when is_binary(same), do: {:error, :cannot_copy_git_signing}

  @doc "Vsock request to write the key on the guest. Do not log it."
  @spec inject_request(binary()) :: map()
  def inject_request(pem) when is_binary(pem) do
    Mjolnir.Vsock.Protocol.inject_file_request(@guest_name, pem)
  end

  # add-honor-git-remote owns Forgejo write-key delete. Returning
  # `:not_wired` (mapped to `:ok`) leaves any remote key as the
  # reconcile find. Do not pretend the delete succeeded.
  defp forgejo_revoke(meta) do
    case hook(:git_signing_forgejo_revoke, meta) do
      :not_wired -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, {:forgejo_revoke, reason}}
      other -> {:error, {:forgejo_revoke, other}}
    end
  end

  defp identikey_revoke_device(meta) do
    cred = meta["credential_id"] || meta[:credential_id]
    xid = meta["xid"] || meta[:xid]

    cond do
      not is_binary(cred) or cred == "" or not is_binary(xid) or xid == "" ->
        # Never registered with identikey — nothing to revoke.
        :ok

      true ->
        case hook(:git_signing_revoke_device, %{xid: xid, credential_id: cred}) do
          :ok -> :ok
          :not_configured -> http_revoke_device(xid, cred)
          {:error, reason} -> {:error, {:revoke_device, reason}}
          other -> {:error, {:revoke_device, other}}
        end
    end
  end

  defp hook(key, meta) do
    case Application.get_env(:mjolnir, key) do
      fun when is_function(fun, 1) -> fun.(meta)
      nil -> if key == :git_signing_forgejo_revoke, do: :not_wired, else: :not_configured
      other -> other
    end
  end

  defp http_revoke_device(xid, credential_id) do
    case identikey_base_url() do
      nil ->
        # No identikey-core issuer configured. Do not delete the identikey
        # row we cannot reach; caller keeps opaque (see revoke/1).
        {:error, :identikey_not_configured}

      base ->
        url = base <> "/devices/ssh_git/revoke"

        case Req.post(url, json: %{xid: xid, credential_id: credential_id}) do
          {:ok, %{status: status}} when status in [200, 204] -> :ok
          {:ok, %{status: 404}} -> :ok
          {:ok, %{status: status, body: body}} -> {:error, {:identikey_http, status, body}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp identikey_base_url do
    case Application.get_env(:mjolnir, :identikey_devices_url) do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/")

      _ ->
        issuer =
          Application.get_env(:mjolnir, :auth, [])
          |> Keyword.get(:issuer, "")

        if is_binary(issuer) and String.contains?(issuer, "auth.identikey.me") do
          issuer
          |> String.trim_trailing("/")
          |> String.replace_suffix("/realms/identikey", "")
        else
          nil
        end
    end
  end

  defp private_in_meta?(meta) do
    keys = Map.keys(meta)

    Enum.any?(keys, fn k ->
      s = if is_atom(k), do: Atom.to_string(k), else: k
      is_binary(s) and String.contains?(s, "private")
    end) or
      Enum.any?(Map.values(meta), fn
        v when is_binary(v) -> String.contains?(v, "PRIVATE KEY")
        _ -> false
      end)
  end

  defp maybe_put_meta(acc, key, meta) do
    val = Map.get(meta, key) || Map.get(meta, atom_key(key))

    if is_binary(val) and val != "" do
      Map.put(acc, key, val)
    else
      acc
    end
  end

  defp atom_key("public_key"), do: :public_key
  defp atom_key("xid"), do: :xid
  defp atom_key("credential_id"), do: :credential_id
  defp atom_key(other), do: other
end
