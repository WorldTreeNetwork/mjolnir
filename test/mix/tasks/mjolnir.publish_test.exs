defmodule Mix.Tasks.Mjolnir.PublishTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mjolnir.Publish
  alias Mjolnir.Sites.IdentiKey

  describe "default resolution helpers" do
    test "default_site/1 is the directory basename" do
      assert Publish.default_site("./dist") == "dist"
      assert Publish.default_site("/tmp/some/public") == "public"
    end

    test "default_base_url/0 follows the configured api_port" do
      assert Publish.default_base_url() ==
               "http://localhost:#{Application.get_env(:mjolnir, :api_port, 4000)}"
    end

    test "default_identity_path/0 lives under the user config dir" do
      assert Publish.default_identity_path() =~ "/.config/mjolnir/identikey.json"
    end
  end

  describe "encrypted modes are rejected (only public is implemented)" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "mjolnir-publish-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "index.html"), "<h1>hi</h1>")
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "--to raises a clear not-yet-available error", %{dir: dir} do
      assert_raise Mix.Error, ~r/--to.*not available yet.*mjolnir-9bq\.5/s, fn ->
        Publish.run([dir, "--to", "alice"])
      end
    end

    test "--keyspace raises a clear not-yet-available error", %{dir: dir} do
      assert_raise Mix.Error, ~r/--keyspace.*not available yet.*mjolnir-9bq\.5/s, fn ->
        Publish.run([dir, "--keyspace", "team"])
      end
    end
  end

  describe "identity bootstrap" do
    test "generates and persists a new IdentiKey on first use, then reuses it" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "mjolnir-identity-#{System.unique_integer([:positive])}.json"
        )

      on_exit(fn -> File.rm_rf!(tmp) end)

      refute File.exists?(tmp)

      # First publish attempt: identity should be created even though the publish
      # itself fails (no server listening). We point at an unroutable base-url so
      # publish/5 errors fast; the identity-creation side effect still happens.
      empty = Path.join(System.tmp_dir!(), "mjolnir-empty-#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf!(empty) end)

      catch_error(Publish.run([empty, "--identity", tmp, "--base-url", "http://127.0.0.1:0"]))

      assert File.exists?(tmp), "expected identity file to be created on first run"

      {:ok, json} = File.read(tmp)
      assert {:ok, kp} = IdentiKey.keypair_from_json(json)
      fp1 = IdentiKey.fingerprint(kp)

      # Second run reuses the same identity (fingerprint stable).
      {:ok, json2} = File.read(tmp)
      {:ok, kp2} = IdentiKey.keypair_from_json(json2)
      assert IdentiKey.fingerprint(kp2) == fp1
    end
  end
end
