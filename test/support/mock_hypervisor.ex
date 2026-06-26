defmodule Mjolnir.Hypervisor.Mock do
  @behaviour Mjolnir.Hypervisor
  @moduledoc """
  Mock hypervisor for unit testing VM lifecycle without KVM.

  Returns success stubs for all callbacks. No real processes are spawned.

  ## Usage

      setup do
        original = Application.get_env(:mjolnir, :hypervisor)
        Application.put_env(:mjolnir, :hypervisor, Mjolnir.Hypervisor.Mock)
        on_exit(fn -> Application.put_env(:mjolnir, :hypervisor, original) end)
      end

  ## Future Enhancements

  Add process-based state tracking (e.g. an Agent) so tests can assert
  which callbacks were called and in what order. This would enable tests like:

      assert Mock.calls() == [:start_vm, :configure_vm, :start_instance]
  """

  @impl true
  def start_vm(_config) do
    # Return self() as a fake port — tests don't send port messages
    {:ok, self()}
  end

  @impl true
  def configure_vm(_socket_path, _config) do
    :ok
  end

  @impl true
  def start_instance(_socket_path) do
    :ok
  end

  @impl true
  def pause_instance(_socket_path) do
    :ok
  end

  @impl true
  def resume_instance(_socket_path) do
    :ok
  end

  @impl true
  def reboot_instance(_socket_path) do
    :ok
  end

  @impl true
  def stop_instance(_socket_path) do
    :ok
  end

  @impl true
  def cleanup(_state) do
    :ok
  end

  @impl true
  def vsock_path(socket_dir, vm_id) do
    Path.join(socket_dir, "mock-vsock-#{vm_id}.sock")
  end

  @impl true
  def process_name do
    "mock-hypervisor"
  end
end
