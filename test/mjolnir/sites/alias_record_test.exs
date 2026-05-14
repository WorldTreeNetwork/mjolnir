defmodule Mjolnir.Sites.AliasRecordTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Sites.AliasRecord

  defp sample_record(overrides \\ %{}) do
    base = %AliasRecord{
      version: 1,
      identikey_fp: "AbCdEfGhIjKl",
      site_name: "blog",
      fqdn: "blog.duke.io",
      sequence: 1,
      created_at: ~U[2026-05-13 12:00:00Z],
      signature: <<1, 2, 3, 4>>
    }

    Map.merge(base, overrides)
  end

  test "serialize/parse round-trip preserves all fields" do
    r = sample_record()
    bytes = AliasRecord.serialize(r)
    assert {:ok, parsed} = AliasRecord.parse(bytes)
    assert parsed.version == r.version
    assert parsed.identikey_fp == r.identikey_fp
    assert parsed.site_name == r.site_name
    assert parsed.fqdn == r.fqdn
    assert parsed.sequence == r.sequence
    assert parsed.created_at == r.created_at
    assert parsed.signature == r.signature
  end

  test "serialize/parse round-trip with nil signature" do
    r = sample_record(%{signature: nil})
    bytes = AliasRecord.serialize(r)
    assert {:ok, parsed} = AliasRecord.parse(bytes)
    assert parsed.signature == nil
  end

  test "canonical_signing_bytes excludes signature field from JSON value" do
    r = sample_record()
    bytes = AliasRecord.canonical_signing_bytes(r)
    {:ok, raw} = Jason.decode(bytes)
    assert raw["signature"] == nil
    # Other fields still present
    assert raw["fqdn"] == "blog.duke.io"
    assert raw["identikey_fp"] == "AbCdEfGhIjKl"
  end

  test "canonical_signing_bytes is same as serialize with nil signature" do
    r = sample_record()
    assert AliasRecord.canonical_signing_bytes(r) == AliasRecord.serialize(%{r | signature: nil})
  end

  test "parse returns error on bad JSON" do
    assert {:error, {:bad_alias_record, _}} = AliasRecord.parse("not json")
  end

  test "parse returns error on missing required field" do
    json = Jason.encode!(%{"version" => 1, "identikey_fp" => "abc"})
    assert {:error, {:bad_alias_record, _}} = AliasRecord.parse(json)
  end

  test "replaces?/2 returns true when candidate has higher sequence" do
    current = sample_record(%{sequence: 5})
    candidate = sample_record(%{sequence: 6})
    assert AliasRecord.replaces?(candidate, current)
  end

  test "replaces?/2 returns false when candidate has lower sequence" do
    current = sample_record(%{sequence: 5})
    candidate = sample_record(%{sequence: 4})
    refute AliasRecord.replaces?(candidate, current)
  end

  test "replaces?/2 uses fqdn tiebreak when sequences are equal" do
    current = sample_record(%{sequence: 5, fqdn: "aaa.example.com"})
    candidate_higher = sample_record(%{sequence: 5, fqdn: "zzz.example.com"})
    candidate_lower = sample_record(%{sequence: 5, fqdn: "aaa.example.com"})

    assert AliasRecord.replaces?(candidate_higher, current)
    refute AliasRecord.replaces?(candidate_lower, current)
  end
end
