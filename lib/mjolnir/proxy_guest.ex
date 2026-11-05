defmodule Mjolnir.ProxyGuest do
  @moduledoc """
  Image-root identity for the proxy network class. Iroh is a consequence of
  this class, never its signal. Both installed boundary files must match the
  versioned recipe in scripts/install-proxy-guest-class.sh byte for byte.
  """
  @network "usr/local/bin/mjolnir-network-setup"
  @drop_in "etc/systemd/system/identikey-api-proxy.service.d/data-dir.conf"
  @network_hash "0ffd2afbf31e79ca32deab17a5f5761870afd85db8e973762e8c02a96fbc6c08"
  @drop_in_hash "e48b237817707e2f466ba1beaff7a84e76d62cd79006a785cb7b07d8eeb0d935"

  @doc "Pure classification of the two image artifacts, independent of VM exec."
  def classify(network, drop_in) when is_binary(network) and is_binary(drop_in) do
    if digest(network) == @network_hash and digest(drop_in) == @drop_in_hash,
      do: :proxy,
      else: :ordinary
  end

  def classify(_, _), do: :ordinary

  def class_for_root(root) when is_binary(root) do
    with {:ok, network} <- File.read(Path.join(root, @network)),
         {:ok, drop_in} <- File.read(Path.join(root, @drop_in)) do
      classify(network, drop_in)
    else
      _ -> :ordinary
    end
  end

  def class_for_root(_), do: :ordinary

  def image_class(base_image) do
    root = Application.get_env(:mjolnir, :btrfs_root)

    if is_binary(root) and is_binary(base_image) and
         Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/, base_image) and
         not String.contains?(base_image, "..") do
      class_for_root(Path.join([root, "@base", base_image]))
    else
      :ordinary
    end
  end

  @doc "Resolve the flag before any guest is started; a proxy cannot opt into Iroh."
  def resolve_iroh(:proxy, true, _default), do: {:error, :proxy_guest_iroh_forbidden}
  def resolve_iroh(:proxy, _, _default), do: {:ok, false}
  def resolve_iroh(:ordinary, nil, default), do: {:ok, default}
  def resolve_iroh(:ordinary, value, _default), do: {:ok, value}

  defp digest(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
