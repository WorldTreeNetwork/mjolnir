# Independent code re-review — accept

Reviewed fix: **54e751c6ff5aea48009983e6846a8b66c06b2cbe** (parent
`a0be321a`). Date: 2026-11-26 UTC. Fresh independent Codex review, no nested
agents. Scope: R1–R3 of `2026-11-26-code-review.md`, the two-file fix diff,
current helper/tests, classifier/owner validation and accepted D4/D5 boundaries.

**ACCEPT the R1–R3 fixes as an unwired reference identity-comparison seam.**
No blocking implementation defect found in this fix. This is neither completed
authentication nor acceptance of the whole node, browser integration, transport
evidence, or deployment. Node remains open and unfolded.

## Resolution of the prior findings

- **R1 resolved at the requested seam.** `RoomJoin.check/4` consumes
  `{:ok, %{token: token, root: root}}` from the trusted caller. The repeated
  token pattern requires the exact response credential; a success for a different
  token refuses. The original admitted root must equal both the independently
  supplied expected root and response root, without normalization. Classification
  follows those comparisons. There is no JWT decoding. Module documentation
  explicitly states that admission is never remote JSON, fabricated success
  authenticates nothing, and no producer or browser lifecycle is wired.
- **R2 resolved by removing the parser.** Array/scalar/null/malformed JSON token
  payloads paired with rejected admission return `:unauthenticated_identity`.
  Malformed outer arguments, absent/non-binary tokens, malformed admission
  shapes, missing/non-string metadata and malformed roots refuse without an
  exception in the independent corpus (including invalid UTF-8 binary roots).
- **R3 resolved.** Presence-aware `Map.fetch` distinguishes absent kind from
  present null/false and other non-enum values. Only a protected root permits
  genuine omission. Open roots require explicit `"open"`. Conflicting atom/string
  token, root and kind fields refuse in both directions; identical duplicates
  remain accepted. Root conflicts report `:response_root_mismatch`, kind conflicts
  `:kind_mismatch`, and token conflicts `:conflicting_fields`.

Positive controls admit both matching kinds. Wrong expected owner, room or sibling
kind refuses. Protected asks reject open credentials. Legacy protected responses
with no kind remain compatible with protected requests; an open request refuses
(`:open_refused` with a protected expected root; `:unexpected_root` with an open
expected root). An open-shaped response missing kind also refuses.

## Nonblocking observations and retained gates

1. `tasks.md`, under “Before first open issuance”, still names `check/3` and calls
   it reusable across join/replacement/renewal. It should name the `check/4`
   reference seam and its trusted-producer prerequisite when the parent next
   updates the gate. The unchecked status and source documentation correctly
   retain the integration boundary; this stale reference does not undo R1.
2. The test wrapper manufactures admission from its fixture token. That is now
   explicitly documented as a stub, not verification. Its missing-token assertion
   returns `:bad_token` inside the wrapper without calling the production helper;
   direct `check/4` returns `:invalid_response`. The independent probes below
   exercise that actual API. The one-iteration identity loop proves no lifecycle.
3. A caller-fabricated success for an opaque string still succeeds by design.
   This API cannot attest provenance or freshness of its own argument. Actual
   integration must obtain current full admission for the credential/operation
   from a trusted producer, retain the original authenticated root and independent
   invitation identity, and apply the comparison before storing credentials or
   starting media. No remote map or merely decoded JWT can be that producer.
4. `.13` still owns full assess on one trust snapshot, grants/path/operation checks
   before relay I/O or SDP, fail-closed key/drain behavior and expiry teardown.
   `.15`/`.5` still own real client join/replacement/renewal integration and tests
   before first open issuance. E2EE, full-root roster/metering and TURN c2 obligations
   remain on their existing downstream gates.
5. Whole-node implementation acceptance still requires independent assessment of
   the sustained participant-confinement and browser product-mint evidence. Grok's
   concurrent transport files were not modified or treated as reviewed evidence.
   No transport/browser run, production access, deploy, fold or node closure here.
   No full-suite rerun: earlier reported full-suite failures are not cleared by
   this focused result. Separate controller deployment authorization remains owed.

The nonblocking follow-ups are recorded on existing bead `mjolnir-rurh.11`;
no duplicate implementation node is needed.

## Independent test results

At the reviewed hash, shell **Elixir/Mix 1.20.4, Erlang/OTP 29**:

```sh
mix test test/mjolnir/relay/mint_test.exs test/mjolnir/relay/room_class_test.exs test/mjolnir/relay/room_join_test.exs test/mjolnir/api/relay_mint_router_test.exs --seed 542751
```

**28 passed, 0 failed**, seed **542751**, 0.2 seconds (0.1 async, 0.1 sync).
Existing compile warnings appeared, including `gateway/classify.ex:337` unpinned
bitstring size. These results do not establish the pinned OTP27 toolchain.

The independent script reproduced below was saved outside the repository and run:

```sh
MIX_ENV=test mix run --no-start --no-compile /tmp/mjolnir-rereview-probes.exs
```

**8 passed, 0 failed**, seed **542751**, 0.07 seconds
(0.07 on load, 0.00 async, 0.00 sync). It calls `check/4` directly, avoiding the
fixture wrapper. Local raw output: `/tmp/mjolnir-rereview-focused.log` and
`/tmp/mjolnir-rereview-probes.log`. Only this review is a Git artifact.

## Reproducible independent probes

```elixir
ExUnit.start(seed: 542751)
defmodule IndependentRoomJoinReReview do
  use ExUnit.Case, async: true
  alias Mjolnir.Relay.RoomJoin
  @owner Mjolnir.Deploy.Owner.encode(:binary.copy(<<9>>, 32))
  @protected "t/#{@owner}/standup"
  @open "t/#{@owner}/~open/standup"
  defp body(root, kind), do: %{"token" => "opaque-credential", "root" => root, "kind" => kind}
  defp admission(root), do: {:ok, %{token: "opaque-credential", root: root}}

  test "direct API rejects malformed outer arguments and token types" do
    for value <- [nil, false, true, 0, 1.0, [], [1], %{}, {:ok, 1}, <<255>>] do
      assert {:error, _} = RoomJoin.check(value, :protected, body(@protected, "protected"), nil)
      assert {:error, _} = RoomJoin.check(@protected, value, body(@protected, "protected"), admission(@protected))
      assert {:error, _} = RoomJoin.check(@protected, :protected, value, admission(@protected))
      assert {:error, _} = RoomJoin.check(@protected, :protected, Map.put(body(@protected, "protected"), "token", value), admission(@protected))
    end
    assert {:error, :invalid_response} = RoomJoin.check(@protected, :protected, %{"root" => @protected}, admission(@protected))
  end

  test "malformed admission and exact credential mismatch refuse" do
    for value <- [nil, false, [], %{}, {:ok, nil}, {:ok, []}, {:ok, %{}}, {:ok, %{root: @protected}}, {:ok, %{token: "opaque-credential", root: nil}}, {:ok, %{"token" => "opaque-credential", "root" => @protected}}, {:ok, %{token: "other", root: @protected}}, {:error, :expired}] do
      assert {:error, :unauthenticated_identity} = RoomJoin.check(@protected, :protected, body(@protected, "protected"), value)
    end
  end

  test "opaque malformed JWTs never yield identity from rejected admission" do
    for payload <- ["[]", "[1]", "null", "1", "true", "\"text\"", "{}", "{\"root\":false}", "bad json"] do
      token = "not-a-header." <> Base.url_encode64(payload) <> "."
      assert {:error, :unauthenticated_identity} = RoomJoin.check(@protected, :protected, Map.put(body(@protected, "protected"), "token", token), {:error, :bad_token})
    end
    # Deliberate boundary control: fabricated success is trusted, NOT authentication.
    assert {:ok, _} = RoomJoin.check(@protected, :protected, body(@protected, "protected"), admission(@protected))
  end

  test "kind presence differs from legacy omission for both key representations" do
    for {root, asked, kind} <- [{@protected, :protected, "protected"}, {@open, :open, "open"}], key <- ["kind", :kind], invalid <- [nil, false, true, 1, [], %{}, :open, "Open", "open ", "", <<255>>] do
      response = body(root, kind) |> Map.delete("kind") |> Map.put(key, invalid)
      assert {:error, :kind_mismatch} = RoomJoin.check(root, asked, response, admission(root))
    end
    assert {:ok, _} = RoomJoin.check(@protected, :protected, Map.delete(body(@protected, "protected"), "kind"), admission(@protected))
    assert {:error, :open_refused} = RoomJoin.check(@protected, :open, Map.delete(body(@protected, "protected"), "kind"), admission(@protected))
    assert {:error, :unexpected_root} = RoomJoin.check(@open, :open, Map.delete(body(@protected, "protected"), "kind"), admission(@protected))
    assert {:error, :kind_mismatch} = RoomJoin.check(@open, :open, Map.delete(body(@open, "open"), "kind"), admission(@open))
  end

  test "all response dual-key conflicts refuse in both directions" do
    for {string, atom} <- [{"token", :token}, {"root", :root}, {"kind", :kind}], invalid <- [nil, false, "other", 1, [], %{}] do
      original = body(@protected, "protected")
      assert {:error, _} = RoomJoin.check(@protected, :protected, Map.put(original, atom, invalid), admission(@protected))
      reversed = original |> Map.put(atom, original[string]) |> Map.put(string, invalid)
      assert {:error, _} = RoomJoin.check(@protected, :protected, reversed, admission(@protected))
    end
    both = Map.merge(body(@protected, "protected"), %{token: "opaque-credential", root: @protected, kind: "protected"})
    assert {:ok, %{root: @protected, kind: :protected}} = RoomJoin.check(@protected, :protected, both, admission(@protected))
  end

  test "expected owner room kind and response root must match exactly" do
    other_owner = Mjolnir.Deploy.Owner.encode(:binary.copy(<<10>>, 32))
    for expected <- ["t/#{other_owner}/standup", "t/#{@owner}/other", @open, @protected <> "/", @protected <> " "] do
      assert {:error, :unexpected_root} = RoomJoin.check(expected, :protected, body(@protected, "protected"), admission(@protected))
    end
    for root <- [nil, false, 1, [], %{}, @open, @protected <> "/", <<255>>] do
      assert {:error, :response_root_mismatch} = RoomJoin.check(@protected, :protected, Map.put(body(@protected, "protected"), "root", root), admission(@protected))
    end
    assert {:error, :response_root_mismatch} = RoomJoin.check(@protected, :protected, Map.delete(body(@protected, "protected"), "root"), admission(@protected))
  end

  test "even trusted root must have exact room grammar" do
    for root <- ["", "t/#{@owner}", "t/#{@owner}/%7Eopen/standup", "t/#{@owner}/~Open/standup", "t/#{@owner}/~open/", "t/#{@owner}/~open/standup/extra", "t/#{@owner}/" <> <<255>>, "t/" <> <<255>> <> "/standup", <<255>>] do
      assert {:error, :invalid_root} = RoomJoin.check(root, :open, body(root, "open"), admission(root))
    end
  end

  test "matching open and protected work and cross-kind requests refuse" do
    assert {:ok, %{root: @open, kind: :open}} = RoomJoin.check(@open, :open, body(@open, "open"), admission(@open))
    assert {:ok, %{root: @protected, kind: :protected}} = RoomJoin.check(@protected, :protected, body(@protected, "protected"), admission(@protected))
    assert {:error, :protected_refused} = RoomJoin.check(@open, :protected, body(@open, "open"), admission(@open))
    assert {:error, :open_refused} = RoomJoin.check(@protected, :open, body(@protected, "protected"), admission(@protected))
  end
end
```
