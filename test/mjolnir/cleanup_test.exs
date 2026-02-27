defmodule Mjolnir.CleanupTest do
  @moduledoc """
  Unit tests for the Cleanup module.
  Tests orphan detection logic without requiring root or real hypervisors.
  """
  use ExUnit.Case, async: true

  alias Mjolnir.Cleanup

  describe "sweep/0" do
    test "returns :ok even when nothing to clean" do
      # sweep should never crash, even if socket_dir doesn't exist
      assert :ok = Cleanup.sweep()
    end
  end
end
