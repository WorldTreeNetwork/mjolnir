defmodule Mjolnir.VMCase do
  use ExUnit.CaseTemplate

  setup do
    # Ensure clean state before each test
    on_exit(fn ->
      # Kill any orphan VMs
      for vm <- Mjolnir.VM.list() do
        Mjolnir.VM.stop(vm.id)
      end
    end)

    :ok
  end
end
