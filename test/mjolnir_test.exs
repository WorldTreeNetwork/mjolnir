defmodule MjolnirTest do
  use ExUnit.Case
  doctest Mjolnir

  test "application starts successfully" do
    # Verify the supervisor is running
    assert Process.whereis(Mjolnir.Supervisor) != nil
  end

  test "VM registry is available" do
    assert Process.whereis(Mjolnir.VMRegistry) != nil
  end

  test "VM supervisor is available" do
    assert Process.whereis(Mjolnir.VMSupervisor) != nil
  end
end
