defmodule Mjolnir.Forge.FileResourceTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Forge.Resource.File, as: FileResource

  # Each test gets its own unique tmp dir, cleaned up on exit.
  setup do
    dir = Path.join(System.tmp_dir!(), "mjolnir-forge-file-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "kind/0" do
    test "returns \"file\"" do
      assert FileResource.kind() == "file"
    end
  end

  describe "canonical/1" do
    test "encoding is stable over key insertion order" do
      content_a = %{path: "/etc/motd", source: "hi\n", mode: 0o644, owner: nil, group: nil}

      content_b = %{
        group: nil,
        mode: 0o644,
        owner: nil,
        path: "/etc/motd",
        source: "hi\n"
      }

      assert FileResource.canonical(content_a) == FileResource.canonical(content_b)
    end

    test "different source produces different canonical" do
      a = %{path: "/etc/motd", source: "hello\n", mode: 0o644, owner: nil, group: nil}
      b = %{path: "/etc/motd", source: "world\n", mode: 0o644, owner: nil, group: nil}
      assert FileResource.canonical(a) != FileResource.canonical(b)
    end

    test "mode and owner are not part of canonical (v0: source-only diff)" do
      # v0 file kind diffs on source bytes only. mode/owner/group are
      # apply-time intentions, not drift signals. Document the trade-off
      # with this test so a future change to canonical/1 has to update it.
      a = %{path: "/etc/motd", source: "x", mode: 0o644, owner: nil, group: nil}
      b = %{path: "/etc/motd", source: "x", mode: 0o600, owner: "root", group: "root"}
      assert FileResource.canonical(a) == FileResource.canonical(b)
    end
  end

  describe "observe_path/1" do
    test "returns {:file, path} — the id IS the path" do
      assert FileResource.observe_path("/etc/motd") == {:file, "/etc/motd"}
    end
  end

  describe "parse_observed/1" do
    test "returns map with just source (v0: mode/owner/group not observed)" do
      assert FileResource.parse_observed("hello\n") == %{source: "hello\n"}
    end
  end

  describe "apply/3" do
    test "writes file at the given path", %{dir: dir} do
      path = Path.join(dir, "motd")
      content = %{path: path, source: "Welcome\n", mode: 0o644, owner: nil, group: nil}
      assert :ok = FileResource.apply("localhost", path, content)
      assert File.read!(path) == "Welcome\n"
    end

    test "creates parent directories if missing", %{dir: dir} do
      path = Path.join([dir, "sub", "dir", "file.conf"])
      content = %{path: path, source: "data", mode: 0o644, owner: nil, group: nil}
      assert :ok = FileResource.apply("localhost", path, content)
      assert File.read!(path) == "data"
    end

    test "apply with mode 0o600 produces file with correct permissions", %{dir: dir} do
      path = Path.join(dir, "secret.conf")
      content = %{path: path, source: "secret", mode: 0o600, owner: nil, group: nil}
      assert :ok = FileResource.apply("localhost", path, content)
      %File.Stat{mode: mode} = File.stat!(path)
      # Lower 9 bits are the rwxrwxrwx bits
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "apply is idempotent — second call overwrites", %{dir: dir} do
      path = Path.join(dir, "idem.txt")
      content = %{path: path, source: "v1", mode: 0o644, owner: nil, group: nil}
      assert :ok = FileResource.apply("localhost", path, content)
      content2 = %{content | source: "v2"}
      assert :ok = FileResource.apply("localhost", path, content2)
      assert File.read!(path) == "v2"
    end
  end

  describe "delete/2" do
    test "removes an existing file", %{dir: dir} do
      path = Path.join(dir, "to_delete.txt")
      File.write!(path, "bye")
      assert :ok = FileResource.delete("localhost", path)
      refute File.exists?(path)
    end

    test "idempotent — delete on missing file returns :ok", %{dir: dir} do
      path = Path.join(dir, "nonexistent.txt")
      assert :ok = FileResource.delete("localhost", path)
      assert :ok = FileResource.delete("localhost", path)
    end
  end
end
