defmodule Mjolnir.TicketTest do
  @moduledoc """
  Unit tests for z-base-32 ticket encoding.
  """
  use ExUnit.Case, async: true

  alias Mjolnir.Ticket

  @z32_alphabet ~c"ybndrfg8ejkmcpqxot1uwisza345h769"

  describe "from_hex/1" do
    test "nil returns nil" do
      assert Ticket.from_hex(nil) == nil
    end

    test "encodes 32-byte hex to 52-char z32" do
      # 32 bytes = 64 hex chars -> 52 z32 chars (256 bits / 5 bits per char = 51.2, padded to 52)
      hex = String.duplicate("ab", 32)
      result = Ticket.from_hex(hex)

      assert is_binary(result)
      assert String.length(result) == 52
    end

    test "output contains only z32 alphabet characters" do
      hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      result = Ticket.from_hex(hex)

      for <<char <- result>> do
        assert char in @z32_alphabet,
               "Character #{<<char>>} (#{char}) not in z32 alphabet"
      end
    end

    test "is deterministic" do
      hex = "deadbeef" <> String.duplicate("00", 28)
      assert Ticket.from_hex(hex) == Ticket.from_hex(hex)
    end

    test "different inputs produce different outputs" do
      hex1 = String.duplicate("aa", 32)
      hex2 = String.duplicate("bb", 32)
      assert Ticket.from_hex(hex1) != Ticket.from_hex(hex2)
    end

    test "handles short input (less than 32 bytes)" do
      # 1 byte = 2 hex chars -> 2 z32 chars (8 bits / 5 = 1.6, padded to 2)
      result = Ticket.from_hex("ff")
      assert is_binary(result)
      assert String.length(result) == 2
    end

    test "handles empty hex string" do
      assert Ticket.from_hex("") == ""
    end
  end
end
