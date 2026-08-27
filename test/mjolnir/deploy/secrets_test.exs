defmodule Mjolnir.Deploy.SecretsTest do
  use ExUnit.Case, async: false

  alias Mjolnir.Deploy.Secrets

  setup do
    original = Application.get_env(:mjolnir, :deploy_secrets_dir)
    dir = Path.join(System.tmp_dir!(), "deploy-secrets-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:mjolnir, :deploy_secrets_dir, dir)

    on_exit(fn ->
      if original,
        do: Application.put_env(:mjolnir, :deploy_secrets_dir, original),
        else: Application.delete_env(:mjolnir, :deploy_secrets_dir)

      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  test "put merges and never drops existing keys", %{dir: dir} do
    File.write!(Path.join(dir, "hypersigil-api.json"), ~s({"DATABASE_URL":"postgres://x"}))

    assert {:ok, result} = Secrets.put("hypersigil-api", %{"STRIPE_API_KEY" => "sk_live_x"})
    assert result.set == ["STRIPE_API_KEY"]
    assert result.keys == ["DATABASE_URL", "STRIPE_API_KEY"]
    refute Map.has_key?(result, :values)

    map = Jason.decode!(File.read!(Path.join(dir, "hypersigil-api.json")))
    assert map["DATABASE_URL"] == "postgres://x"
    assert map["STRIPE_API_KEY"] == "sk_live_x"
  end

  test "list_keys returns names only" do
    assert {:ok, _} = Secrets.put("shop", %{"JWT_SECRET" => "s3cret"})
    assert {:ok, listing} = Secrets.list_keys("shop")
    assert listing.keys == ["JWT_SECRET"]
    refute inspect(listing) =~ "s3cret"
  end

  test "unset removes one key and keeps the rest", %{dir: dir} do
    assert {:ok, _} = Secrets.put("shop", %{"A" => "1", "B" => "2"})
    assert {:ok, result} = Secrets.delete("shop", "A")
    assert result.unset == "A"
    assert result.keys == ["B"]
    assert Jason.decode!(File.read!(Path.join(dir, "shop.json"))) == %{"B" => "2"}
  end

  test "unset of a missing key is not_found" do
    assert {:error, :not_found} = Secrets.delete("shop", "NOPE")
  end

  test "rejects empty maps, empty values, and invalid names" do
    assert {:error, :empty} = Secrets.put("shop", %{})
    assert {:error, {:invalid_value, "FOO"}} = Secrets.put("shop", %{"FOO" => ""})
    assert {:error, {:invalid_key, "not-a-key"}} = Secrets.put("shop", %{"not-a-key" => "x"})
  end

  test "slug matches deploy filenames" do
    assert Secrets.slug("HyperSigil API") == "hypersigil_api"
    assert Secrets.slug("hypersigil-api") == "hypersigil-api"
  end
end
