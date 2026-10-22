defmodule Mjolnir.Deploy.ForgejoOwnersTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Deploy.ForgejoOwners

  @a "CZ8YUVdk7znjrUmnb5n7kgySk9yRAsQDYmyCxzfSky9t"
  @b "3dLGACrVKP67MtW4kwbG54JqBGS5nSb46uZVkJNueWKJ"
  @hex "27060fd66283eb5c6c900bce5b364fa512fb4c718b6af18acc7720c424e08821"

  setup do
    file =
      Path.join(System.tmp_dir!(), "forgejo-owners-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(file) end)
    {:ok, owners_path: file}
  end

  test "repo override wins over the account, and lookup is case-insensitive", %{owners_path: file} do
    assert {:ok, @a} = ForgejoOwners.put_account("Acme", @a, file)
    assert {:ok, @b} = ForgejoOwners.put_repo("acme", "Client-App", @b, file)

    assert ForgejoOwners.resolve("acme/other", file) == {:ok, @a}
    assert ForgejoOwners.resolve("ACME/client-app", file) == {:ok, @b}
    assert ForgejoOwners.resolve("nobody/app", file) == :error
  end

  test "hex is not a link, and delete removes the row", %{owners_path: file} do
    assert {:error, :invalid_owner} = ForgejoOwners.put_account("acme", @hex, file)
    assert {:error, :invalid_login} = ForgejoOwners.put_account("has space", @a, file)
    assert {:error, :invalid_login} = ForgejoOwners.put_account("resolve", @a, file)

    assert {:ok, @a} = ForgejoOwners.put_account("acme", "  #{@a}  ", file)
    assert :ok = ForgejoOwners.delete_account("ACME", file)
    assert ForgejoOwners.resolve("acme/app", file) == :error
  end

  test "a missing file resolves as unlinked", %{owners_path: file} do
    File.rm(file)
    assert ForgejoOwners.resolve("acme/app", file) == :error
  end
end
