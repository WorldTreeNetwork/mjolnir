defmodule Mjolnir.AIE.Sidecar do
  @moduledoc """
  Locator and presence for the AIE overlay sidecar.

  `aie_url` is injected only when `/dev/accel/accel0` exists and the
  `mjolnir-aie` unit is active. The sidecar process is not an IdentiKey
  and is never given `operator.sock`.
  """

  @device_path "/dev/accel/accel0"
  @unit "mjolnir-aie"

  @doc """
  Overlay origin, or `nil` when the sidecar is off.
  """
  @spec locator_url() :: String.t() | nil
  def locator_url do
    if available?() do
      ip = Application.get_env(:mjolnir, :host_api_ip, "10.200.0.1")
      port = Application.get_env(:mjolnir, :aie_compute_port, 7422)
      "http://#{ip}:#{port}"
    end
  end

  @spec available?() :: boolean()
  def available?, do: device_present?() and unit_active?()

  @spec device_present?() :: boolean()
  def device_present? do
    path = Application.get_env(:mjolnir, :aie_device_path, @device_path)
    is_binary(path) and File.exists?(path)
  end

  @spec unit_active?() :: boolean()
  def unit_active? do
    case Application.get_env(:mjolnir, :aie_unit_active) do
      true -> true
      false -> false
      _ -> systemctl_active?()
    end
  end

  defp systemctl_active? do
    case System.cmd("systemctl", ["is-active", "--quiet", @unit], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end
end
