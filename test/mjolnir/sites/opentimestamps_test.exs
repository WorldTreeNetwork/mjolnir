defmodule Mjolnir.Sites.OpenTimestampsTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Sites.OpenTimestamps

  @sample_bytes "hello opentimestamps"

  test "available?/0 returns a boolean" do
    result = OpenTimestamps.available?()
    assert is_boolean(result)
  end

  test "submit/1 returns {:error, :ots_not_installed} when ots is unavailable" do
    if OpenTimestamps.available?() do
      # ots IS present — unavailability path cannot be tested; pass silently
      :ok
    else
      assert {:error, :ots_not_installed} = OpenTimestamps.submit(@sample_bytes)
    end
  end

  test "upgrade/1 returns {:error, :ots_not_installed} when ots is unavailable" do
    if OpenTimestamps.available?() do
      :ok
    else
      assert {:error, :ots_not_installed} = OpenTimestamps.upgrade("fake-receipt-bytes")
    end
  end

  test "verify/2 returns {:error, :ots_not_installed} when ots is unavailable" do
    if OpenTimestamps.available?() do
      :ok
    else
      assert {:error, :ots_not_installed} =
               OpenTimestamps.verify(@sample_bytes, "fake-receipt-bytes")
    end
  end

  # The following tests require `ots` to be installed and make real network
  # calls to the OpenTimestamps calendar servers. They guard internally so they
  # pass (rather than fail) when ots is absent. Run with
  # `mix test --only requires_ots` on a host with ots installed.

  @tag :requires_ots
  test "submit/1 returns pending receipt bytes when ots is available" do
    if OpenTimestamps.available?() do
      assert {:ok, receipt_bytes} = OpenTimestamps.submit(@sample_bytes)
      assert is_binary(receipt_bytes)
      assert byte_size(receipt_bytes) > 0
    end
  end

  @tag :requires_ots
  test "upgrade/1 returns :still_pending for a freshly submitted receipt" do
    if OpenTimestamps.available?() do
      {:ok, receipt_bytes} = OpenTimestamps.submit(@sample_bytes)
      # A brand-new receipt cannot be Bitcoin-anchored yet.
      result = OpenTimestamps.upgrade(receipt_bytes)
      assert match?({:ok, :still_pending}, result) or match?({:ok, :upgraded, _}, result)
    end
  end
end
