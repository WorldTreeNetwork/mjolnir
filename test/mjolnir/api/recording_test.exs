defmodule Mjolnir.Sites.Storage.RecordingProbeSpy do
  @moduledoc false
  @behaviour Mjolnir.Sites.Storage

  def put_chunk(_, _, _), do: :ok

  def get_chunk(hash) do
    notify({:get, hash})
    :not_found
  end

  def has_chunk?(hash) do
    notify({:has, hash})
    false
  end

  def chunk_present?(hash) do
    notify({:head, hash})

    case File.stat(Mjolnir.Sites.Store.chunk_path(hash)) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 -> true
      _ -> false
    end
  end

  defp notify(message) do
    case Application.get_env(:mjolnir, :recording_probe_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end
end

defmodule Mjolnir.API.RecordingTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Mjolnir.API.SitesRouter
  alias Mjolnir.Sites.{Crypto, Store, WrapShape}

  @opts SitesRouter.init([])

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("mjolnir-recording-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([tmp, "blob", "b3"]))
    File.mkdir_p!(Path.join([tmp, "manifests"]))

    orig_sites = Application.get_env(:mjolnir, :sites_root)
    orig_backend = Application.get_env(:mjolnir, :sites_storage_backend)
    orig_url = Application.get_env(:mjolnir, :recrypt_storage_url)
    Application.put_env(:mjolnir, :sites_root, tmp)
    Application.put_env(:mjolnir, :recording_probe_pid, self())

    on_exit(fn ->
      Application.put_env(:mjolnir, :sites_root, orig_sites)
      Application.put_env(:mjolnir, :sites_storage_backend, orig_backend)

      if is_binary(orig_url) do
        Application.put_env(:mjolnir, :recrypt_storage_url, orig_url)
      else
        Application.delete_env(:mjolnir, :recrypt_storage_url)
      end

      Application.delete_env(:mjolnir, :recording_probe_pid)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "owner wrap is stored for a blob the backend can stat", %{tmp: tmp} do
    hash = put_blob()
    owner = xid()
    wrap = wrap_bytes(7)
    conn = post_register(hash, owner, wrap, "sub-a")

    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert body["hash"] == hash
    assert body["owner_xid"] == owner
    assert body["friends"] == []
    assert Base.url_decode64!(body["wrap"], padding: false) == wrap
    assert Map.keys(body) |> Enum.sort() == ["friends", "hash", "owner_xid", "wrap"]

    path = Path.join([tmp, "recordings", hash <> ".json"])
    assert File.regular?(path)
    refute String.starts_with?(Path.relative_to(path, tmp), "blob/b3")
    on_disk = File.read!(path) |> Jason.decode!()
    assert on_disk["owner_sub"] == "sub-a"
    refute Map.has_key?(body, "owner_sub")

    again = post_register(hash, owner, wrap, "sub-a")
    assert again.status == 200
    assert Jason.decode!(again.resp_body)["wrap"] == body["wrap"]
  end

  test "a second different owner wrap loses, and the stored wrap stays" do
    hash = put_blob()
    owner = xid()
    first = wrap_bytes(1)
    second = wrap_bytes(2)
    assert post_register(hash, owner, first, "sub-a").status == 201

    refused = post_register(hash, owner, second, "sub-a")
    assert refused.status == 409
    assert Jason.decode!(refused.resp_body)["error"] == "wrap_conflict"

    kept = Jason.decode!(call(:get, "/recordings/#{hash}", "", :user, "sub-a").resp_body)
    assert Base.url_decode64!(kept["wrap"], padding: false) == first
  end

  test "two concurrent different wraps produce one success" do
    hash = put_blob()
    owner = xid()
    first = Task.async(fn -> post_register(hash, owner, wrap_bytes(3), "sub-a") end)
    second = Task.async(fn -> post_register(hash, owner, wrap_bytes(4), "sub-a") end)
    statuses = Enum.sort([Task.await(first).status, Task.await(second).status])
    assert statuses == [201, 409]

    {:ok, row} = Store.fetch_recording(hash)
    assert row["owner_sub"] == "sub-a"
    assert length(row["friends"]) == 0
  end

  test "a missing blob inserts nothing", %{tmp: tmp} do
    hash = unused_hash()
    conn = post_register(hash, xid(), wrap_bytes(1), "sub-a")
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"] == "blob_missing"
    refute File.exists?(Path.join([tmp, "recordings", hash <> ".json"]))
  end

  test "the owner is not a friend of their own blob" do
    hash = put_blob()
    owner = xid()
    assert post_register(hash, owner, wrap_bytes(1), "sub-a").status == 201

    conn =
      call(
        :post,
        "/recordings/#{hash}/friends",
        Jason.encode!(%{friend_xid: owner, wrap: b64(wrap_bytes(5))}),
        :user,
        "sub-a"
      )

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "owner_is_not_friend"

    assert Jason.decode!(call(:get, "/recordings/#{hash}", "", :user, "sub-a").resp_body)[
             "friends"
           ] ==
             []
  end

  test "a different sub cannot register, add a friend, or read the index" do
    hash = put_blob()
    owner = xid()
    wrap = wrap_bytes(1)
    assert post_register(hash, owner, wrap, "sub-a").status == 201

    same_wrap = post_register(hash, owner, wrap, "sub-b")
    assert same_wrap.status == 403
    assert Jason.decode!(same_wrap.resp_body)["error"] == "not_owner"

    friend = xid()

    added =
      call(
        :post,
        "/recordings/#{hash}/friends",
        Jason.encode!(%{friend_xid: friend, wrap: b64(wrap_bytes(6))}),
        :user,
        "sub-b"
      )

    assert added.status == 403
    assert Jason.decode!(added.resp_body)["error"] == "not_owner"

    read = call(:get, "/recordings/#{hash}", "", :user, "sub-b")
    assert read.status == 403
    decoded = Jason.decode!(read.resp_body)
    assert decoded["error"] == "not_owner"
    refute Map.has_key?(decoded, "friends")
    refute Map.has_key?(decoded, "wrap")

    assert call(
             :post,
             "/recordings/#{hash}/friends",
             Jason.encode!(%{friend_xid: friend, wrap: b64(wrap_bytes(6))}),
             :user,
             "sub-a"
           ).status == 201

    mine = Jason.decode!(call(:get, "/recordings/#{hash}", "", :user, "sub-a").resp_body)
    assert [%{"friend_xid" => ^friend}] = mine["friends"]
    raw = Base.url_decode64!(mine["wrap"], padding: false)
    assert WrapShape.valid?(raw)
    assert byte_size(raw) != 32
  end

  test "a biscuit, a Sites token, and other non-user kinds are refused before a probe", %{
    tmp: tmp
  } do
    Application.put_env(:mjolnir, :sites_storage_backend, Mjolnir.Sites.Storage.RecordingProbeSpy)
    hash = unused_hash()
    body = Jason.encode!(%{hash: hash, owner_xid: xid(), wrap: b64(wrap_bytes(1))})

    for {kind, user_id} <- [
          {:capability, "capability"},
          {:sites, "sites_token:abc"},
          {:operator, "localhost"},
          {:ceremony, nil},
          {:public, nil}
        ] do
      conn = call(:post, "/recordings", body, kind, user_id)
      assert conn.status == 403, inspect(kind)
      assert Jason.decode!(conn.resp_body)["error"] == "forbidden"
      assert call(:get, "/recordings/#{hash}", "", kind, user_id).status == 403

      assert call(
               :post,
               "/recordings/#{hash}/friends",
               Jason.encode!(%{friend_xid: xid(), wrap: b64(wrap_bytes(1))}),
               kind,
               user_id
             ).status == 403
    end

    refute_received {:head, _}
    refute_received {:get, _}
    refute_received {:has, _}
    refute File.exists?(Path.join([tmp, "recordings", hash <> ".json"]))
  end

  test "register stats or HEADs and does not download the ciphertext" do
    hash = put_blob()
    Application.put_env(:mjolnir, :sites_storage_backend, Mjolnir.Sites.Storage.RecordingProbeSpy)

    conn = post_register(hash, xid(), wrap_bytes(1), "sub-a")
    assert conn.status == 201
    assert_received {:head, ^hash}
    refute_received {:get, _}
    refute_received {:has, _}
  end

  test "a raw 32-byte body inserts nothing", %{tmp: tmp} do
    hash = put_blob()
    raw = :crypto.strong_rand_bytes(32)
    conn = post_register(hash, xid(), raw, "sub-a")
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] == "bad_wrap"
    refute File.exists?(Path.join([tmp, "recordings", hash <> ".json"]))
    refute WrapShape.valid?(raw)
    refute WrapShape.valid?(<<0x58, 32, raw::binary>>)
  end

  test "the wrap file is what a restarted store reads", %{tmp: tmp} do
    hash = put_blob()
    assert post_register(hash, xid(), wrap_bytes(9), "sub-a").status == 201
    path = Path.join([tmp, "recordings", hash <> ".json"])
    assert File.regular?(path)

    old = Process.whereis(Mjolnir.Sites.Store)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}, 2_000

    conn = call(:get, "/recordings/#{hash}", "", :user, "sub-a")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["hash"] == hash

    assert wait_store(old)
  end

  test "the door presence check is a HEAD" do
    parent = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    door = spawn(fn -> door_loop(listen, parent) end)

    Application.put_env(:mjolnir, :sites_storage_backend, Mjolnir.Sites.Storage.Recrypt)
    Application.put_env(:mjolnir, :recrypt_storage_url, "http://127.0.0.1:#{port}")

    hash = unused_hash()

    try do
      assert Store.chunk_present?(hash)
      assert_received {:door, "HEAD"}
      refute_received {:door, "GET"}
    after
      :gen_tcp.close(listen)
      Process.exit(door, :kill)
    end
  end

  test "wrap shape accepts the key-wrap map and rejects trailing bytes" do
    assert WrapShape.valid?(wrap_bytes(1))
    assert WrapShape.valid?(full_wrap())
    refute WrapShape.valid?(wrap_bytes(1) <> <<0>>)
    refute WrapShape.valid?(<<0xBF, 0xFF>>)
    refute WrapShape.valid?(<<>>)
    long = :binary.copy(<<1>>, 4097)

    refute WrapShape.valid?(
             <<0xA2, 0x63, "alg", 0x78, 24, "x25519-xchacha20poly1305", 0x59, 4097::16,
               long::binary>>
           )
  end

  defp post_register(hash, owner, wrap, sub) do
    call(
      :post,
      "/recordings",
      Jason.encode!(%{hash: hash, owner_xid: owner, wrap: b64(wrap)}),
      :user,
      sub
    )
  end

  defp call(method, path, body, kind, user_id) do
    conn(method, path, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:principal_kind, kind)
    |> assign(:user_id, user_id)
    |> SitesRouter.call(@opts)
  end

  defp put_blob do
    Enum.find_value(1..40, fn _ ->
      ciphertext = :crypto.strong_rand_bytes(48)
      hash = Crypto.blake3_hash_base58(ciphertext)

      if Store.valid_blob_hash?(hash) do
        :ok = Store.put_chunk(hash, ciphertext, <<>>)
        hash
      end
    end) || flunk("no usable blake3 hash")
  end

  defp unused_hash do
    Enum.find_value(1..40, fn _ ->
      hash = Mjolnir.Base58.encode(:crypto.strong_rand_bytes(32))
      if Store.valid_blob_hash?(hash), do: hash
    end) || flunk("no usable hash")
  end

  defp xid, do: Mjolnir.Base58.encode(:crypto.strong_rand_bytes(32))

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp wrap_bytes(fill) do
    ct = :binary.copy(<<fill>>, 48)

    <<0xA2, 0x63, "alg", 0x78, 24, "x25519-xchacha20poly1305", 0x6A, "ciphertext", 0x58, 48,
      ct::binary>>
  end

  defp full_wrap do
    <<0xA6>> <>
      tstr("alg") <>
      tstr("x25519-xchacha20poly1305") <>
      tstr("ciphertext") <>
      bstr(:binary.copy(<<9>>, 48)) <>
      tstr("ephemeral") <>
      bstr(:binary.copy(<<2>>, 32)) <>
      tstr("epoch") <>
      <<0>> <>
      tstr("nonce") <>
      bstr(:binary.copy(<<3>>, 24)) <>
      tstr("recipient") <>
      bstr(:binary.copy(<<4>>, 32))
  end

  defp tstr(text) when byte_size(text) < 24, do: <<0x60 + byte_size(text), text::binary>>
  defp tstr(text), do: <<0x78, byte_size(text), text::binary>>
  defp bstr(bytes), do: <<0x58, byte_size(bytes), bytes::binary>>

  defp wait_store(old, n \\ 50)
  defp wait_store(_old, 0), do: flunk("Sites.Store did not restart")

  defp wait_store(old, n) do
    case Process.whereis(Mjolnir.Sites.Store) do
      pid when is_pid(pid) and pid != old ->
        true

      _ ->
        Process.sleep(20)
        wait_store(old, n - 1)
    end
  end

  defp door_loop(listen, parent) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, sock} ->
        method = read_http(sock, "")
        send(parent, {:door, method})
        body = if method == "GET", do: "ciphertext", else: ""

        :gen_tcp.send(
          sock,
          "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
            body
        )

        :gen_tcp.close(sock)
        door_loop(listen, parent)

      _ ->
        :ok
    end
  end

  defp read_http(_sock, acc) when byte_size(acc) > 2048, do: "TRUNC"

  defp read_http(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc |> String.split(" ") |> hd()
    else
      case :gen_tcp.recv(sock, 0, 2_000) do
        {:ok, data} -> read_http(sock, acc <> data)
        _ -> "ERR"
      end
    end
  end
end
