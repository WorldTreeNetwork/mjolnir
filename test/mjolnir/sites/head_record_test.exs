defmodule Mjolnir.Sites.HeadRecordTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Sites.HeadRecord

  defp sample(opts \\ []) do
    %HeadRecord{
      version: 1,
      identikey_fp: Keyword.get(opts, :fp, "abc123"),
      site_name: Keyword.get(opts, :name, "blog"),
      snapshot_hash: Keyword.get(opts, :hash, "deadbeef"),
      sequence: Keyword.get(opts, :seq, 1),
      created_at: ~U[2026-05-13 12:00:00Z],
      signature: <<1, 2, 3>>
    }
  end

  test "serialize then parse round-trips" do
    r = sample()
    bytes = HeadRecord.serialize(r)
    assert {:ok, parsed} = HeadRecord.parse(bytes)
    assert parsed.identikey_fp == r.identikey_fp
    assert parsed.snapshot_hash == r.snapshot_hash
    assert parsed.sequence == r.sequence
    assert parsed.signature == r.signature
  end

  test "replaces?/2 prefers higher sequence" do
    current = sample(seq: 5)
    newer = sample(seq: 6, hash: "newer")
    assert HeadRecord.replaces?(newer, current)
    refute HeadRecord.replaces?(current, newer)
  end

  test "replaces?/2 tie-breaks on snapshot hash when sequence equal" do
    a = sample(seq: 5, hash: "aaa")
    b = sample(seq: 5, hash: "bbb")
    assert HeadRecord.replaces?(b, a)
    refute HeadRecord.replaces?(a, b)
  end
end
