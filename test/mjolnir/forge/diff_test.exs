defmodule Mjolnir.Forge.DiffTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Forge.{Canonical, Diff}

  # Lightweight fake kind so we exercise Diff without touching SystemdUnit's
  # filesystem assumptions. Diff only calls `canonical/1` on the module.
  defmodule FakeKind do
    @behaviour Mjolnir.Forge.Resource
    @impl true
    def kind, do: "fake"
    @impl true
    def canonical(%{body: b}), do: b
    @impl true
    def observe_path(_), do: :probe
    @impl true
    def parse_observed(b), do: %{body: b}
    @impl true
    def probe(_, _), do: :missing
    @impl true
    def apply(_, _, _), do: :ok
    @impl true
    def delete(_, _), do: :ok
  end

  defp content(s), do: %{body: s}
  defp hash(s), do: Canonical.hash_bytes(s)
  defp key(id), do: {FakeKind, id}

  describe "compute/3 matrix" do
    test ":new when declared but not owned and not observed" do
      [entry] = Diff.compute(%{key("a") => content("x")}, %{}, %{key("a") => :missing})
      assert entry.status == :new
    end

    test ":new when declared, no owned, no observed entry at all" do
      [entry] = Diff.compute(%{key("a") => content("x")}, %{}, %{})
      assert entry.status == :new
    end

    test ":converged when declared, owned, observed match" do
      h = hash("x")

      [entry] =
        Diff.compute(
          %{key("a") => content("x")},
          %{key("a") => h},
          %{key("a") => {:present, content("x")}}
        )

      assert entry.status == :converged
    end

    test ":drifted when declared and owned but observed differs" do
      [entry] =
        Diff.compute(
          %{key("a") => content("x")},
          %{key("a") => hash("x")},
          %{key("a") => {:present, content("y")}}
        )

      assert entry.status == :drifted
    end

    test ":missing when declared and owned but observed is :missing" do
      [entry] =
        Diff.compute(
          %{key("a") => content("x")},
          %{key("a") => hash("x")},
          %{key("a") => :missing}
        )

      assert entry.status == :missing
    end

    test ":conflict when declared, no owned, observed differs" do
      [entry] =
        Diff.compute(
          %{key("a") => content("x")},
          %{},
          %{key("a") => {:present, content("y")}}
        )

      assert entry.status == :conflict
    end

    test "auto-adopt-on-exact-match: declared, no owned, observed matches → :converged" do
      [entry] =
        Diff.compute(
          %{key("a") => content("x")},
          %{},
          %{key("a") => {:present, content("x")}}
        )

      assert entry.status == :converged
    end

    test ":prune when not declared, owned, and observed present" do
      [entry] =
        Diff.compute(
          %{},
          %{key("a") => hash("x")},
          %{key("a") => {:present, content("x")}}
        )

      assert entry.status == :prune
    end

    test ":tombstone when not declared, owned, observed gone" do
      [entry] =
        Diff.compute(
          %{},
          %{key("a") => hash("x")},
          %{key("a") => :missing}
        )

      assert entry.status == :tombstone
    end

    test ":unmanaged when not declared, not owned, but observed present" do
      [entry] =
        Diff.compute(
          %{},
          %{},
          %{key("a") => {:present, content("x")}}
        )

      assert entry.status == :unmanaged
    end
  end

  test "diff carries declared and observed content for downstream apply/display" do
    [entry] =
      Diff.compute(
        %{key("a") => content("declared body")},
        %{},
        %{key("a") => {:present, content("observed body")}}
      )

    assert entry.declared_content == %{body: "declared body"}
    assert entry.observed_content == %{body: "observed body"}
  end

  test "compute returns one entry per unique key across all three maps" do
    entries =
      Diff.compute(
        %{key("a") => content("x")},
        %{key("b") => hash("y")},
        %{key("c") => {:present, content("z")}}
      )

    statuses = Enum.map(entries, & &1.status) |> Enum.sort()
    # a: declared only → :new
    # b: owned only, observed missing → :tombstone
    # c: observed only → :unmanaged
    assert statuses == [:new, :tombstone, :unmanaged]
  end
end
