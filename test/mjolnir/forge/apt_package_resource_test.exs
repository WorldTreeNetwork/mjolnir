defmodule Mjolnir.Forge.AptPackageResourceTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Forge.Resource.AptPackage

  setup do
    # Enable sandbox mode so we don't run real apt commands
    prev = Application.get_env(:mjolnir, :forge_apt_sandbox)
    Application.put_env(:mjolnir, :forge_apt_sandbox, true)
    AptPackage.ensure_sandbox_table()

    on_exit(fn ->
      if prev,
        do: Application.put_env(:mjolnir, :forge_apt_sandbox, prev),
        else: Application.delete_env(:mjolnir, :forge_apt_sandbox)

      # Clean up sandbox table entries (but leave the table — other tests may use it)
      if :ets.whereis(:forge_apt_sandbox) != :undefined do
        :ets.delete_all_objects(:forge_apt_sandbox)
      end
    end)

    :ok
  end

  describe "kind/0" do
    test "returns \"apt_package\"" do
      assert AptPackage.kind() == "apt_package"
    end
  end

  describe "canonical/1" do
    test "installed without version" do
      assert AptPackage.canonical(%{state: :installed, version: nil}) == "installed"
    end

    test "installed with version" do
      assert AptPackage.canonical(%{state: :installed, version: "1.2.3"}) == "installed:1.2.3"
    end

    test "held with version" do
      assert AptPackage.canonical(%{state: :held, version: "50.0"}) == "held:50.0"
    end

    test "removed" do
      assert AptPackage.canonical(%{state: :removed, version: nil}) == "removed"
    end

    test "different states produce different canonical" do
      a = AptPackage.canonical(%{state: :installed, version: nil})
      b = AptPackage.canonical(%{state: :removed, version: nil})
      assert a != b
    end
  end

  describe "observe_path/1" do
    test "returns :probe" do
      assert AptPackage.observe_path("nginx") == :probe
    end
  end

  describe "parse_observed/1" do
    test "parses installed with version" do
      assert AptPackage.parse_observed("installed 1.24.0-1") ==
               %{state: :installed, version: "1.24.0-1"}
    end

    test "parses hold with version" do
      assert AptPackage.parse_observed("hold 50.0-1ubuntu1") ==
               %{state: :held, version: "50.0-1ubuntu1"}
    end

    test "parses unknown status as removed" do
      assert AptPackage.parse_observed("not-installed") ==
               %{state: :removed, version: nil}
    end
  end

  describe "probe/2 (sandbox)" do
    test "returns :missing for uninstalled package" do
      assert AptPackage.probe("localhost", "nonexistent-pkg") == :missing
    end

    test "returns content for installed package" do
      :ets.insert(:forge_apt_sandbox, {"nginx", %{state: :installed, version: "1.24.0"}})

      assert {:ok, %{state: :installed, version: "1.24.0"}} =
               AptPackage.probe("localhost", "nginx")
    end
  end

  describe "apply/3 (sandbox)" do
    test "install a package" do
      content = %{state: :installed, version: "1.0.0"}
      assert :ok = AptPackage.apply("localhost", "test-pkg", content)
      assert {:ok, ^content} = AptPackage.probe("localhost", "test-pkg")
    end

    test "hold a package" do
      content = %{state: :held, version: "2.0.0"}
      assert :ok = AptPackage.apply("localhost", "held-pkg", content)
      assert {:ok, ^content} = AptPackage.probe("localhost", "held-pkg")
    end

    test "remove a package" do
      # First install
      AptPackage.apply("localhost", "rm-pkg", %{state: :installed, version: "1.0"})
      # Then remove
      assert :ok = AptPackage.apply("localhost", "rm-pkg", %{state: :removed, version: nil})
      assert AptPackage.probe("localhost", "rm-pkg") == :missing
    end

    test "apply is idempotent" do
      content = %{state: :installed, version: "3.0"}
      assert :ok = AptPackage.apply("localhost", "idem-pkg", content)
      assert :ok = AptPackage.apply("localhost", "idem-pkg", content)
      assert {:ok, ^content} = AptPackage.probe("localhost", "idem-pkg")
    end
  end

  describe "delete/2 (sandbox)" do
    test "removes a package from the sandbox" do
      AptPackage.apply("localhost", "del-pkg", %{state: :installed, version: "1.0"})
      assert :ok = AptPackage.delete("localhost", "del-pkg")
      assert AptPackage.probe("localhost", "del-pkg") == :missing
    end

    test "idempotent — delete on missing returns :ok" do
      assert :ok = AptPackage.delete("localhost", "never-existed")
    end
  end
end
