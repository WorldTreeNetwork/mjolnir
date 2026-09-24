defmodule Mjolnir.GitSigningTest do
  use ExUnit.Case, async: false

  alias Mjolnir.{GitSigning, SecretStore, Vsock.Protocol}
  alias Mjolnir.Forgejo.DeployKeys

  setup do
    root = Path.join(System.tmp_dir!(), "mj-git-signing-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    original = Application.get_env(:mjolnir, :secret_store_root, nil)
    Application.put_env(:mjolnir, :secret_store_root, root)
    Application.put_env(:mjolnir, :forgejo_token, nil)

    on_exit(fn ->
      if original, do: Application.put_env(:mjolnir, :secret_store_root, original)
      Application.put_env(:mjolnir, :forgejo_token, nil)
      Application.delete_env(:mjolnir, :forgejo_http)
      Application.delete_env(:mjolnir, :git_signing_forgejo_register)
      Application.delete_env(:mjolnir, :git_signing_forgejo_revoke)
      Application.delete_env(:mjolnir, :git_signing_revoke_device)
      File.rm_rf(root)
    end)

    {:ok, vm_id: "01234567-89ab-cdef-0123-456789abcdef"}
  end

  test "put/get round-trip is opaque and 0600", %{vm_id: vm_id} do
    pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----\n"
    assert :ok = GitSigning.put(vm_id, pem)
    assert {:ok, ^pem} = GitSigning.get(vm_id)

    path = Path.join([SecretStore.root(), "_opaque", "vms", vm_id, "git_signing"])
    %{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "inject_request is not the Buzz env map" do
    req = GitSigning.inject_request("SECRETKEY")
    assert req["type"] == "inject_file"
    assert req["name"] == "git_signing_key"
    assert req["contents"] == "SECRETKEY"
    refute Map.has_key?(req, "entries")
  end

  test "protocol inject_file is distinct from inject_identity" do
    id_req = Protocol.inject_identity_request(%{private_key_nsec: "nsec1x", relay_url: "wss://x"})
    file_req = Protocol.inject_file_request("git_signing_key", "k")
    assert id_req["type"] == "inject_identity"
    assert file_req["type"] == "inject_file"
    refute Map.has_key?(id_req, "name")
  end

  test "mint does not copy opaque across vm_ids", %{vm_id: vm_id} do
    other = "fedcba98-7654-3210-fedc-ba9876543210"
    assert {:ok, pub1} = GitSigning.mint(vm_id)
    assert {:ok, pub2} = GitSigning.mint(other)
    assert pub1 != pub2
    assert {:ok, pem1} = GitSigning.get(vm_id)
    assert {:ok, pem2} = GitSigning.get(other)
    assert pem1 != pem2
    assert {:ok, meta} = GitSigning.get_device(vm_id)
    refute is_map_key(meta, "private_key")
    refute inspect(meta) =~ "PRIVATE KEY"
  end

  test "put_device refuses private key material", %{vm_id: vm_id} do
    pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----\n"

    assert {:error, :private_key_not_on_device_meta} =
             GitSigning.put_device(vm_id, %{private_key: pem})

    assert :not_found = GitSigning.get_device(vm_id)
  end

  test "respawn mints a new key and refuses same-id copy", %{vm_id: vm_id} do
    other = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    assert {:ok, pub1} = GitSigning.mint(vm_id)
    assert {:ok, pem1} = GitSigning.get(vm_id)
    assert {:ok, pub2} = GitSigning.respawn(vm_id, other)
    assert pub1 != pub2
    assert :not_found = GitSigning.get(vm_id)
    assert {:ok, pem2} = GitSigning.get(other)
    assert pem1 != pem2
    assert {:error, :cannot_copy_git_signing} = GitSigning.respawn(other, other)
  end

  test "revoke order is Forgejo then revoke_device then opaque", %{vm_id: vm_id} do
    assert {:ok, _pub} = GitSigning.mint(vm_id)

    :ok =
      GitSigning.put_device(vm_id, %{
        public_key: "ssh-ed25519 AAAA",
        xid: "aa",
        credential_id: "11111111-1111-1111-1111-111111111111"
      })

    {:ok, order} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      Application.delete_env(:mjolnir, :git_signing_forgejo_revoke)
      Application.delete_env(:mjolnir, :git_signing_revoke_device)
    end)

    Application.put_env(:mjolnir, :git_signing_forgejo_revoke, fn _meta ->
      Agent.update(order, &(&1 ++ [:forgejo]))
      :not_wired
    end)

    Application.put_env(:mjolnir, :git_signing_revoke_device, fn meta ->
      Agent.update(order, &(&1 ++ [:revoke_device]))
      assert meta.xid == "aa"
      assert meta.credential_id == "11111111-1111-1111-1111-111111111111"
      :ok
    end)

    assert :ok = GitSigning.revoke(vm_id)
    assert Agent.get(order, & &1) == [:forgejo, :revoke_device]
    assert :not_found = GitSigning.get(vm_id)
    assert :not_found = GitSigning.get_device(vm_id)
  end

  test "revoke_device failure keeps the opaque live", %{vm_id: vm_id} do
    pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nlive\n-----END OPENSSH PRIVATE KEY-----\n"
    assert :ok = GitSigning.put(vm_id, pem)

    :ok =
      GitSigning.put_device(vm_id, %{
        xid: "bb",
        credential_id: "22222222-2222-2222-2222-222222222222"
      })

    on_exit(fn ->
      Application.delete_env(:mjolnir, :git_signing_forgejo_revoke)
      Application.delete_env(:mjolnir, :git_signing_revoke_device)
    end)

    Application.put_env(:mjolnir, :git_signing_forgejo_revoke, fn _ -> :not_wired end)

    Application.put_env(:mjolnir, :git_signing_revoke_device, fn _ ->
      {:error, :identikey_down}
    end)

    assert {:error, {:revoke_device, :identikey_down}} = GitSigning.revoke(vm_id)
    assert {:ok, ^pem} = GitSigning.get(vm_id)
  end

  test "unconfigured forgejo is :not_wired reconcile find", %{vm_id: vm_id} do
    Application.put_env(:mjolnir, :forgejo_token, nil)
    Application.delete_env(:mjolnir, :forgejo_http)

    assert :not_wired =
             DeployKeys.register(%{public_key: "ssh-ed25519 AAAA", vm_id: vm_id})

    assert :not_wired =
             DeployKeys.revoke(%{public_key: "ssh-ed25519 AAAA", forgejo_key_id: "1"})

    pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nlive\n-----END OPENSSH PRIVATE KEY-----\n"
    assert :ok = GitSigning.put(vm_id, pem)
    assert :ok = GitSigning.revoke(vm_id)
    assert :not_found = GitSigning.get(vm_id)
  end

  test "mint registers a write deploy key and revoke deletes it", %{vm_id: vm_id} do
    {agent, http} = start_fake_forgejo()
    Application.put_env(:mjolnir, :forgejo_token, "test-token")
    Application.put_env(:mjolnir, :forgejo_http, http)

    assert {:ok, pub} = GitSigning.mint(vm_id)
    assert {:ok, meta0} = GitSigning.get_device(vm_id)
    refute is_map_key(meta0, "forgejo_key_id")

    :ok =
      GitSigning.put_device(vm_id, %{
        xid: "aa",
        credential_id: "11111111-1111-1111-1111-111111111111"
      })

    assert {:ok, meta} = GitSigning.get_device(vm_id)
    assert meta["forgejo_key_id"] == "1"
    refute is_map_key(meta, "private_key")

    [post] = Agent.get(agent, & &1.posts)
    assert post["read_only"] == false
    assert post["title"] =~ vm_id

    assert String.contains?(
             post["key"],
             String.trim(pub) |> String.split() |> Enum.take(2) |> Enum.join(" ")
           )

    {:ok, order} = Agent.start_link(fn -> [] end)

    Application.put_env(:mjolnir, :git_signing_revoke_device, fn _ ->
      Agent.update(order, &(&1 ++ [:revoke_device]))
      :ok
    end)

    assert :ok = GitSigning.revoke(vm_id)
    assert Agent.get(order, & &1) == [:revoke_device]
    assert Agent.get(agent, & &1.keys) == %{}
    assert :not_found = GitSigning.get(vm_id)
    assert :not_found = GitSigning.get_device(vm_id)
  end

  test "failed Forgejo delete keeps opaque and skips revoke_device", %{vm_id: vm_id} do
    {agent, http} = start_fake_forgejo()
    Application.put_env(:mjolnir, :forgejo_token, "test-token")
    Application.put_env(:mjolnir, :forgejo_http, http)

    assert {:ok, _pub} = GitSigning.mint(vm_id)
    assert {:ok, pem} = GitSigning.get(vm_id)

    :ok =
      GitSigning.put_device(vm_id, %{
        xid: "bb",
        credential_id: "22222222-2222-2222-2222-222222222222"
      })

    Agent.update(agent, &Map.put(&1, :fail_delete, true))

    called = Agent.start_link(fn -> false end) |> elem(1)

    Application.put_env(:mjolnir, :git_signing_revoke_device, fn _ ->
      Agent.update(called, fn _ -> true end)
      :ok
    end)

    assert {:error, {:forgejo_revoke, {:http_status, 500, _}}} = GitSigning.revoke(vm_id)
    assert {:ok, ^pem} = GitSigning.get(vm_id)
    assert Agent.get(called, & &1) == false
    assert map_size(Agent.get(agent, & &1.keys)) == 1
  end

  test "attach register failure does not create a deploy key", %{vm_id: vm_id} do
    {agent, http} = start_fake_forgejo(fail_post: true)
    Application.put_env(:mjolnir, :forgejo_token, "test-token")
    Application.put_env(:mjolnir, :forgejo_http, http)

    assert {:ok, _pub} = GitSigning.mint(vm_id)

    assert {:error, {:forgejo_register, {:http_status, 500, _}}} =
             GitSigning.put_device(vm_id, %{
               xid: "cc",
               credential_id: "33333333-3333-3333-3333-333333333333"
             })

    assert Agent.get(agent, & &1.keys) == %{}
    assert {:ok, meta} = GitSigning.get_device(vm_id)
    refute present_forgejo_id?(meta)
  end

  test "mint without identikey row does not register Forgejo", %{vm_id: vm_id} do
    {agent, http} = start_fake_forgejo()
    Application.put_env(:mjolnir, :forgejo_token, "test-token")
    Application.put_env(:mjolnir, :forgejo_http, http)

    assert {:ok, _pub} = GitSigning.mint(vm_id)
    assert Agent.get(agent, & &1.posts) == []
    assert Agent.get(agent, & &1.keys) == %{}
  end

  test "revoke fails closed when token is missing after a grant", %{vm_id: vm_id} do
    {_agent, http} = start_fake_forgejo()
    Application.put_env(:mjolnir, :forgejo_token, "test-token")
    Application.put_env(:mjolnir, :forgejo_http, http)

    assert {:ok, _pub} = GitSigning.mint(vm_id)

    :ok =
      GitSigning.put_device(vm_id, %{
        xid: "dd",
        credential_id: "44444444-4444-4444-4444-444444444444"
      })

    Application.put_env(:mjolnir, :forgejo_token, nil)
    assert {:error, {:forgejo_revoke, :token_missing}} = GitSigning.revoke(vm_id)
    assert {:ok, _} = GitSigning.get(vm_id)
  end

  defp present_forgejo_id?(meta) do
    id = meta["forgejo_key_id"]
    (is_binary(id) and id != "") or (is_integer(id) and id > 0)
  end

  test "respawn deletes the old Forgejo key and registers the new pubkey", %{vm_id: vm_id} do
    {agent, http} = start_fake_forgejo()
    Application.put_env(:mjolnir, :forgejo_token, "test-token")
    Application.put_env(:mjolnir, :forgejo_http, http)

    other = "fedcba98-7654-3210-fedc-ba9876543210"
    assert {:ok, pub1} = GitSigning.mint(vm_id)

    Application.put_env(:mjolnir, :git_signing_revoke_device, fn _ -> :ok end)

    :ok =
      GitSigning.put_device(vm_id, %{
        xid: "ee",
        credential_id: "55555555-5555-5555-5555-555555555555"
      })

    assert {:ok, pub2} = GitSigning.respawn(vm_id, other)

    :ok =
      GitSigning.put_device(other, %{
        xid: "ff",
        credential_id: "66666666-6666-6666-6666-666666666666"
      })

    assert pub1 != pub2
    assert :not_found = GitSigning.get(vm_id)
    assert {:ok, _} = GitSigning.get(other)

    keys = Agent.get(agent, &Map.values(&1.keys))
    assert length(keys) == 1
    [remaining] = keys
    blob2 = pub2 |> String.trim() |> String.split() |> Enum.take(2) |> Enum.join(" ")
    assert remaining["key"] |> String.split() |> Enum.take(2) |> Enum.join(" ") == blob2
    assert remaining["title"] =~ other
    refute remaining["title"] =~ vm_id

    assert {:ok, meta} = GitSigning.get_device(other)
    assert meta["forgejo_key_id"] == "2"
  end

  defp start_fake_forgejo(opts \\ []) do
    fail_post = Keyword.get(opts, :fail_post, false)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{next_id: 1, keys: %{}, posts: [], fail_delete: false, fail_post: fail_post}
      end)

    http = fn method, url, headers, body ->
      authorized =
        Enum.any?(headers, fn {k, v} ->
          String.downcase(to_string(k)) == "authorization" and
            is_binary(v) and String.starts_with?(v, "token ")
        end)

      cond do
        not authorized ->
          {:ok, 401, %{"message" => "unauthorized"}}

        true ->
          Agent.get_and_update(agent, fn state ->
            fake_dispatch(state, method, url, body)
          end)
      end
    end

    {agent, http}
  end

  defp fake_dispatch(%{fail_post: true} = state, :post, _url, _body) do
    {{:ok, 500, %{"message" => "nope"}}, state}
  end

  defp fake_dispatch(state, :post, _url, body) do
    blob = key_blob(body["key"])

    exists =
      Enum.any?(Map.values(state.keys), fn k -> key_blob(k["key"]) == blob end)

    if exists do
      {{:ok, 422, %{"message" => "exists"}}, state}
    else
      id = state.next_id

      rec = %{
        "id" => id,
        "key" => body["key"],
        "title" => body["title"],
        "read_only" => body["read_only"]
      }

      {{:ok, 201, rec},
       %{
         state
         | next_id: id + 1,
           keys: Map.put(state.keys, id, rec),
           posts: state.posts ++ [body]
       }}
    end
  end

  defp fake_dispatch(state, :get, _url, _body) do
    {{:ok, 200, Map.values(state.keys)}, state}
  end

  defp fake_dispatch(%{fail_delete: true} = state, :delete, _url, _body) do
    {{:ok, 500, %{"message" => "nope"}}, state}
  end

  defp fake_dispatch(state, :delete, url, _body) do
    id =
      url
      |> String.split("/")
      |> List.last()
      |> String.to_integer()

    {{:ok, 204, nil}, %{state | keys: Map.delete(state.keys, id)}}
  end

  defp key_blob(key) when is_binary(key) do
    key |> String.trim() |> String.split() |> Enum.take(2) |> Enum.join(" ")
  end

  defp key_blob(_), do: ""
end
