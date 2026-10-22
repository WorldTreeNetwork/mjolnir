defmodule Mjolnir do
  @moduledoc """
  Mjolnir - Distributed computational fabric for spawning checkpointable Linux microVMs.

  Copyright (C) 2026 World Tree Network Foundation. AGPL-3.0-or-later
  (the `mj` CLI in `native/mjolnir_client` is MIT). See NOTICE.

  ## Quick Start

      # Spawn a VM
      {:ok, vm} = Mjolnir.VM.spawn(%{base_image: "ubuntu-24.04", memory_mb: 1024})

      # Execute a command
      {:ok, output} = Mjolnir.VM.exec(vm.id, "uname -a")

      # Stop the VM
      :ok = Mjolnir.VM.stop(vm.id)

  """
end
