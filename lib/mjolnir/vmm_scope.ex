defmodule Mjolnir.VmmScope do
  @moduledoc """
  Per-VM systemd scope under `mjolnir-vms.slice`.

  The slice is a sibling of `mjolnir.service`. Stopping the orchestrator
  does not kill these scopes. `VM.stop` kills the one scope for that VM.
  """

  @slice "mjolnir-vms.slice"

  @spec slice() :: String.t()
  def slice, do: @slice

  @spec scope_unit(String.t()) :: String.t()
  def scope_unit(vm_id) when is_binary(vm_id) do
    "mjolnir-" <> sanitize(vm_id) <> ".scope"
  end

  @doc """
  `systemd-run` argv that starts `exe` inside this VM's scope.

  The orchestrator unit name is not an argument. The scope is.
  """
  @spec spawn_command(String.t(), [String.t()], String.t()) :: {String.t(), [String.t()]}
  def spawn_command(exe, args, vm_id)
      when is_binary(exe) and is_list(args) and is_binary(vm_id) do
    {"systemd-run",
     [
       "--scope",
       "--slice=#{@slice}",
       "--unit=#{scope_unit(vm_id)}",
       "--collect",
       "--",
       exe
       | args
     ]}
  end

  @doc """
  Argv that kills this VM's scope, not `mjolnir.service`.
  """
  @spec stop_command(String.t()) :: {String.t(), [String.t()]}
  def stop_command(vm_id) when is_binary(vm_id) do
    {"systemctl", ["kill", "--kill-who=all", scope_unit(vm_id)]}
  end

  @spec stop(String.t()) :: :ok
  def stop(vm_id) when is_binary(vm_id) do
    {cmd, args} = stop_command(vm_id)

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp sanitize(vm_id) do
    String.replace(vm_id, ~r/[^A-Za-z0-9-]/, "_")
  end
end
