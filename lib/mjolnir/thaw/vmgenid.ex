defmodule Mjolnir.Thaw.Vmgenid do
  @moduledoc """
  Capture provenance and the guest generation-id publish gate.

  Cloud Hypervisor v54 exposes VMGENID without a configuration knob. Kernel
  CRNG reseeding does not reset userspace PRNGs. Neither an entropy ioctl nor
  a urandom sample proves that the guest observed a generation-id change.
  """

  @doc """
  Ask the guest for the VM Generation ID sysfs value.

  `nil` and a transport failure are `:missing`. A response is an id only when
  `interpret/1` accepts it. A `/dev/urandom` sample is not a shape this
  function returns.
  """
  def observe(nil), do: :missing

  def observe(conn) when is_pid(conn) do
    case Mjolnir.Vsock.Connection.send_request(conn, request(), 10_000) do
      {:ok, response} -> interpret(response)
      {:error, _reason} -> :missing
    end
  end

  def observe(_conn), do: :missing

  @doc "Build a `get_vmgenid` request. The boot agent answers this too."
  def request(id \\ nil) do
    %{"type" => "get_vmgenid", "id" => id || UUID.uuid4()}
  end

  @doc """
  Classify a `vmgenid_response`.

  Success is `ok: true` and a 32-digit hex id, the 16-byte counter. Every
  other payload, including an old agent's error, is `:missing`.
  """
  def interpret(%{"type" => "vmgenid_response", "ok" => true, "generation_id" => id})
      when is_binary(id) do
    if generation_id?(id), do: {:ok, String.downcase(id)}, else: :missing
  end

  def interpret(_response), do: :missing

  defp generation_id?(id) do
    byte_size(id) == 32 and String.match?(id, ~r/^[0-9a-fA-F]+$/)
  end

  @doc "Record the boot kernel capability and a genuine observation, if available."
  def capture(vm, observe \\ &observe/1) do
    %{
      "config_vmgenid" => Map.get(vm, :kernel_vmgenid),
      "generation_id" => observation_id(observe.(Map.get(vm, :vsock_conn)))
    }
  end

  # Read the embedded IKCONFIG from the actual boot image, never infer support
  # from a version number or from an unrelated host /boot/config file.
  def kernel_support(path) when is_binary(path) do
    with {:ok, image} <- File.read(path),
         [_, rest] <- :binary.split(image, "IKCFG_ST"),
         [compressed, _] <- :binary.split(rest, "IKCFG_ED") do
      config = :zlib.gunzip(compressed)

      cond do
        Regex.match?(~r/^CONFIG_VMGENID=y$/m, config) -> true
        Regex.match?(~r/^# CONFIG_VMGENID is not set$/m, config) -> false
        true -> nil
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def kernel_support(_), do: nil

  @doc "Legacy and unsupported captures continue without claiming a change."
  def verify(%{"config_vmgenid" => true} = record, observation) do
    captured = record["generation_id"]
    observed = observation_id(observation)

    cond do
      is_nil(captured) or is_nil(observed) -> {:error, :vmgenid_observation_missing}
      captured == observed -> {:error, :vmgenid_unchanged}
      true -> {:ok, %{changed: true, generation_id: observed}}
    end
  end

  def verify(_record, _observation), do: {:ok, %{changed: false}}

  defp observation_id({:ok, id}) when is_binary(id) and byte_size(id) > 0, do: id
  defp observation_id(_), do: nil
end
