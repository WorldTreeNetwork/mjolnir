defmodule Mjolnir.Forge.UserResourceTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Forge.Resource.User

  setup do
    prev = Application.get_env(:mjolnir, :forge_user_sandbox)
    Application.put_env(:mjolnir, :forge_user_sandbox, true)
    User.ensure_sandbox_table()

    on_exit(fn ->
      if prev,
        do: Application.put_env(:mjolnir, :forge_user_sandbox, prev),
        else: Application.delete_env(:mjolnir, :forge_user_sandbox)

      if :ets.whereis(:forge_user_sandbox) != :undefined do
        :ets.delete_all_objects(:forge_user_sandbox)
      end
    end)

    :ok
  end

  describe "kind/0" do
    test "returns \"user\"" do
      assert User.kind() == "user"
    end
  end

  describe "canonical/1" do
    test "encodes state only" do
      assert User.canonical(%{state: :present}) == "state=present"
    end

    test "encodes all fields" do
      content = %{
        state: :present,
        uid: 999,
        shell: "/bin/bash",
        home: "/home/duke",
        groups: ["sudo", "docker"]
      }

      canonical = User.canonical(content)
      assert canonical =~ "state=present"
      assert canonical =~ "uid=999"
      assert canonical =~ "shell=/bin/bash"
      assert canonical =~ "home=/home/duke"
      assert canonical =~ "groups=docker,sudo"
    end

    test "groups are sorted for stability" do
      a = User.canonical(%{state: :present, groups: ["z", "a", "m"]})
      b = User.canonical(%{state: :present, groups: ["m", "z", "a"]})
      assert a == b
    end

    test "absent state" do
      assert User.canonical(%{state: :absent}) == "state=absent"
    end

    test "nil fields are excluded" do
      content = %{state: :present, uid: nil, shell: nil, home: nil, groups: nil}
      assert User.canonical(content) == "state=present"
    end
  end

  describe "observe_path/1" do
    test "returns :probe" do
      assert User.observe_path("mjolnir") == :probe
    end
  end

  describe "parse_observed/1" do
    test "parses passwd-style line" do
      line = "mjolnir:x:1000:1000:Mjolnir User:/home/mjolnir:/bin/bash"
      result = User.parse_observed(line)
      assert result.state == :present
      assert result.uid == 1000
      assert result.home == "/home/mjolnir"
      assert result.shell == "/bin/bash"
    end

    test "returns absent for unparseable input" do
      assert User.parse_observed("garbage") == %{state: :absent}
    end
  end

  describe "probe/2 (sandbox)" do
    test "returns :missing for nonexistent user" do
      assert User.probe("localhost", "nobody-here") == :missing
    end

    test "returns content for existing user" do
      content = %{
        state: :present,
        uid: 999,
        shell: "/bin/bash",
        home: "/home/test",
        groups: nil,
        system: true
      }

      :ets.insert(:forge_user_sandbox, {"testuser", content})
      assert {:ok, ^content} = User.probe("localhost", "testuser")
    end
  end

  describe "apply/3 (sandbox)" do
    test "create a user" do
      content = %{
        state: :present,
        uid: 1001,
        shell: "/bin/zsh",
        home: "/home/newuser",
        groups: ["sudo"],
        system: false
      }

      assert :ok = User.apply("localhost", "newuser", content)
      assert {:ok, ^content} = User.probe("localhost", "newuser")
    end

    test "remove a user" do
      content = %{
        state: :present,
        uid: 1001,
        shell: "/bin/bash",
        home: "/home/rm",
        groups: nil,
        system: false
      }

      User.apply("localhost", "rmuser", content)
      assert :ok = User.apply("localhost", "rmuser", %{state: :absent})
      assert User.probe("localhost", "rmuser") == :missing
    end

    test "apply is idempotent" do
      content = %{
        state: :present,
        uid: 500,
        shell: "/usr/sbin/nologin",
        home: "/nonexistent",
        groups: nil,
        system: true
      }

      assert :ok = User.apply("localhost", "svc", content)
      assert :ok = User.apply("localhost", "svc", content)
      assert {:ok, ^content} = User.probe("localhost", "svc")
    end
  end

  describe "delete/2 (sandbox)" do
    test "removes user from sandbox" do
      User.apply("localhost", "delme", %{
        state: :present,
        uid: 1002,
        shell: "/bin/sh",
        home: "/tmp",
        groups: nil,
        system: false
      })

      assert :ok = User.delete("localhost", "delme")
      assert User.probe("localhost", "delme") == :missing
    end

    test "idempotent — delete missing user returns :ok" do
      assert :ok = User.delete("localhost", "ghost")
    end
  end
end
