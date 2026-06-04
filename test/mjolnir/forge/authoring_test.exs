defmodule Mjolnir.Forge.AuthoringTest do
  @moduledoc """
  `Mjolnir.Forge.Authoring` (per-resource `.adopted.exs` files) plus the
  Declarations source-path tracking it depends on. Not async — overrides the
  global `:forge_declarations_path` and drives the Declarations singleton.
  """

  use ExUnit.Case, async: false

  alias Mjolnir.Forge.{Authoring, Declarations}
  alias Mjolnir.Forge.Resource.SystemdUnit

  setup do
    n = System.unique_integer([:positive])
    decls_dir = Path.join(System.tmp_dir!(), "forge-authoring-#{n}")
    File.mkdir_p!(decls_dir)

    prev = Application.get_env(:mjolnir, :forge_declarations_path)
    Application.put_env(:mjolnir, :forge_declarations_path, decls_dir)
    Declarations.reload()

    on_exit(fn ->
      Application.put_env(:mjolnir, :forge_declarations_path, prev)
      _ = File.rm_rf(decls_dir)
      Declarations.reload()
    end)

    %{decls_dir: decls_dir}
  end

  describe "naming" do
    test "adopted_path is deterministic and ends in .adopted.exs", %{decls_dir: dir} do
      p1 = Authoring.adopted_path("self", "systemd_unit", "foo.service")
      p2 = Authoring.adopted_path("self", "systemd_unit", "foo.service")
      assert p1 == p2
      assert String.starts_with?(p1, dir)
      assert String.ends_with?(p1, ".adopted.exs")
    end

    test "different resources get different paths" do
      a = Authoring.adopted_path("self", "systemd_unit", "a.service")
      b = Authoring.adopted_path("self", "systemd_unit", "b.service")
      c = Authoring.adopted_path("other", "systemd_unit", "a.service")
      assert a != b
      assert a != c
    end

    test "forge_owned? distinguishes adopted files from hand-written ones" do
      assert Authoring.forge_owned?(Authoring.adopted_path("self", "file", "/etc/x"))
      refute Authoring.forge_owned?("/repo/forge/declarations/self.exs")
      refute Authoring.forge_owned?(nil)
    end
  end

  describe "write/4 + reload" do
    test "an adopted file loads back as a declaration with matching content", %{decls_dir: _dir} do
      content = %{source: "[Unit]\nDescription=Adopted\n", enabled: nil, state: nil}
      {:ok, path} = Authoring.write("self", SystemdUnit, "adopted.service", content)

      assert File.exists?(path)
      assert Authoring.forge_owned?(path)

      :ok = Declarations.reload()

      entry =
        Declarations.for_host("self")
        |> Enum.find(fn {_kind, id, _content} -> id == "adopted.service" end)

      assert {SystemdUnit, "adopted.service", parsed} = entry
      assert SystemdUnit.canonical(parsed) == SystemdUnit.canonical(content)
    end

    test "source_path points back at the adopted file" do
      content = %{source: "[Unit]\nDescription=Track\n", enabled: nil, state: nil}
      {:ok, path} = Authoring.write("self", SystemdUnit, "track.service", content)
      :ok = Declarations.reload()

      assert Declarations.source_path("self", "systemd_unit", "track.service") == path
    end

    test "re-writing the same resource overwrites the same file in place" do
      {:ok, p1} =
        Authoring.write("self", SystemdUnit, "rw.service", %{
          source: "v1\n",
          enabled: nil,
          state: nil
        })

      {:ok, p2} =
        Authoring.write("self", SystemdUnit, "rw.service", %{
          source: "v2\n",
          enabled: nil,
          state: nil
        })

      assert p1 == p2

      :ok = Declarations.reload()

      {SystemdUnit, "rw.service", parsed} =
        Declarations.for_host("self") |> Enum.find(fn {_, id, _} -> id == "rw.service" end)

      assert parsed.source == "v2\n"
    end

    test "remove/3 deletes the adopted file (idempotent)" do
      {:ok, path} =
        Authoring.write("self", SystemdUnit, "rm.service", %{
          source: "x\n",
          enabled: nil,
          state: nil
        })

      assert File.exists?(path)
      assert :ok = Authoring.remove("self", "systemd_unit", "rm.service")
      refute File.exists?(path)
      # second remove is a no-op
      assert :ok = Authoring.remove("self", "systemd_unit", "rm.service")
    end
  end

  describe "Declarations.source_path/3" do
    test "tracks the source file of a hand-written declaration", %{decls_dir: dir} do
      src = """
      defmodule HandWritten do
        use Mjolnir.Forge.Declaration, host: "hw"
        systemd_unit "hand.service" do
          source "[Unit]\\nDescription=Hand\\n"
        end
      end
      """

      hand_path = Path.join(dir, "hw.exs")
      File.write!(hand_path, src)
      :ok = Declarations.reload()

      assert Declarations.source_path("hw", "systemd_unit", "hand.service") == hand_path
    end

    test "returns nil for an unknown resource" do
      assert Declarations.source_path("nope", "systemd_unit", "ghost.service") == nil
    end
  end
end
