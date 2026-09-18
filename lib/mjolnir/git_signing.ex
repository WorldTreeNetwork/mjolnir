defmodule Mjolnir.GitSigning do
  @moduledoc """
  Opaque SSH git-signing key for a hosted being.

  Private material lives in SecretStore `_opaque/vms/<id>/git_signing`
  and is injected to `/run/mjolnir/git_signing_key`. Never on the VM
  struct, StateStore, or API views.
  """

  @store_kind "vms"
  @opaque_key "git_signing"
  @guest_name "git_signing_key"

  @doc "Persist an OpenSSH private key for `vm_id`."
  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(vm_id, pem) when is_binary(vm_id) and is_binary(pem) and pem != "" do
    Mjolnir.SecretStore.put_opaque(@store_kind, vm_id, @opaque_key, pem)
  end

  @spec get(String.t()) :: {:ok, binary()} | :not_found | {:error, term()}
  def get(vm_id), do: Mjolnir.SecretStore.get_opaque(@store_kind, vm_id, @opaque_key)

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(vm_id), do: Mjolnir.SecretStore.delete_opaque(@store_kind, vm_id, @opaque_key)

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

  @doc "Vsock request to write the key on the guest. Do not log it."
  @spec inject_request(binary()) :: map()
  def inject_request(pem) when is_binary(pem) do
    Mjolnir.Vsock.Protocol.inject_file_request(@guest_name, pem)
  end
end
