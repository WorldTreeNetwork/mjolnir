defmodule Mjolnir.Hypervisor do
  @moduledoc """
  Behaviour defining the hypervisor abstraction layer for Mjolnir.

  This module provides a pluggable interface for different hypervisor backends.
  Currently, Firecracker is the only implementation, but this abstraction enables
  future support for other VMMs like Cloud Hypervisor or QEMU.

  ## Configuration

  Set the hypervisor implementation in config:

      config :mjolnir, :hypervisor, Mjolnir.Hypervisor.Firecracker

  ## Callbacks

  All hypervisors must implement the following lifecycle and management operations:

  - `start_vm/1` - Launch the hypervisor process
  - `configure_vm/2` - Configure VM resources via API
  - `start_instance/1` - Boot the VM
  - `pause_instance/1` - Pause execution
  - `resume_instance/1` - Resume execution
  - `stop_instance/1` - Stop the VM
  - `cleanup/1` - Clean up resources
  - `vsock_path/2` - Get the vsock socket path
  - `process_name/0` - Get the hypervisor process name for cleanup
  """

  @doc """
  Start the hypervisor process.

  Launches the hypervisor binary and returns a Port reference.

  ## Parameters

  - `config` - Map containing VM configuration including:
    - `:vm_id` - VM identifier
    - `:socket_path` - API socket path
    - `:serial_path` - Serial console path (optional)
    - `:firecracker_bin` - Path to hypervisor binary
    - `:wrapper_script` - Path to console wrapper script (optional)

  ## Returns

  - `{:ok, port}` - Port reference to the hypervisor process
  - `{:error, term}` - Error reason
  """
  @callback start_vm(config :: map()) :: {:ok, port()} | {:error, term()}

  @doc """
  Configure the VM via the hypervisor's API.

  Sets up boot source, drives, machine config, vsock, and networking.

  ## Parameters

  - `socket_path` - Path to the hypervisor's API socket
  - `config` - `Mjolnir.Firecracker.Config` struct with VM settings

  ## Returns

  - `:ok` - Configuration succeeded
  - `{:error, term}` - Configuration error
  """
  @callback configure_vm(socket_path :: String.t(), config :: map()) :: :ok | {:error, term()}

  @doc """
  Start the VM instance.

  Boots the configured VM, transitioning from configured to running state.

  ## Parameters

  - `socket_path` - Path to the hypervisor's API socket

  ## Returns

  - `:ok` - Instance started
  - `{:error, term}` - Start failed
  """
  @callback start_instance(socket_path :: String.t()) :: :ok | {:error, term()}

  @doc """
  Pause the VM instance.

  Freezes VM execution, typically for snapshotting.

  ## Parameters

  - `socket_path` - Path to the hypervisor's API socket

  ## Returns

  - `:ok` - Instance paused
  - `{:error, term}` - Pause failed
  """
  @callback pause_instance(socket_path :: String.t()) :: :ok | {:error, term()}

  @doc """
  Resume a paused VM instance.

  Unfreezes VM execution after pause.

  ## Parameters

  - `socket_path` - Path to the hypervisor's API socket

  ## Returns

  - `:ok` - Instance resumed
  - `{:error, term}` - Resume failed
  """
  @callback resume_instance(socket_path :: String.t()) :: :ok | {:error, term()}

  @doc """
  Stop the VM instance.

  Terminates VM execution gracefully.

  ## Parameters

  - `socket_path` - Path to the hypervisor's API socket

  ## Returns

  - `:ok` - Instance stopped
  - `{:error, term}` - Stop failed
  """
  @callback stop_instance(socket_path :: String.t()) :: :ok | {:error, term()}

  @doc """
  Clean up all VM resources.

  Terminates the hypervisor process, removes sockets, deletes rootfs, and
  cleans up network interfaces.

  ## Parameters

  - `state` - Map containing cleanup metadata:
    - `:hypervisor_port` - Port reference
    - `:socket_path` - API socket path
    - `:vsock_path` - Vsock socket path
    - `:serial_path` - Serial socket path
    - `:rootfs_path` - Root filesystem path
    - `:net_config` - Network configuration
    - `:id` - VM identifier

  ## Returns

  - `:ok` - Cleanup completed
  """
  @callback cleanup(state :: map()) :: :ok

  @doc """
  Get the vsock socket path for a VM.

  Returns the path to the Unix domain socket used for vsock communication.

  ## Parameters

  - `socket_dir` - Directory where sockets are stored
  - `vm_id` - VM identifier

  ## Returns

  - Path string to vsock socket
  """
  @callback vsock_path(socket_dir :: String.t(), vm_id :: String.t()) :: String.t()

  @doc """
  Get the hypervisor process name for cleanup.

  Returns the process name used to identify orphaned hypervisor processes
  during startup cleanup.

  ## Returns

  - Process name string (e.g., "firecracker")
  """
  @callback process_name() :: String.t()

  @doc """
  Get the configured hypervisor implementation module.

  Reads from application config or defaults to Firecracker.

  ## Examples

      Mjolnir.Hypervisor.impl()
      #=> Mjolnir.Hypervisor.Firecracker
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:mjolnir, :hypervisor, Mjolnir.Hypervisor.Firecracker)
  end
end
