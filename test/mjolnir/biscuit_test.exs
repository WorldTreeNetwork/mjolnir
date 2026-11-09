defmodule Mjolnir.BiscuitTest do
  use ExUnit.Case, async: false

  alias Mjolnir.Biscuit

  @empty Base.decode16!(
           "AF1349B9F5F9A1A6A0404DEA36DCC9499BCB25C9ADC112B7CC9A93CAE41F3262",
           case: :upper
         )

  test "blake3_hash empty-string known-answer vector" do
    assert Biscuit.blake3_hash("") == @empty
    assert Biscuit.blake3_hash("") == Biscuit.empty_vector()
  end

  test "holder fingerprint is algorithm-committing" do
    pub = :binary.copy(<<0x11>>, 32)
    fp = Biscuit.holder_fingerprint(pub)
    assert byte_size(fp) == 32
    refute fp == Biscuit.blake3_hash(pub)
  end

  test "secret commit is domain-separated and 32 bytes" do
    c = Biscuit.secret_commit("salt", "secret")
    assert byte_size(c) == 32
    refute c == Biscuit.blake3_hash("secret")
  end

  test "mint round-trip, holder check, and tamper" do
    %{private_hex: priv, public_hex: pub} = Biscuit.keypair()
    minted = Biscuit.mint(priv, "github-pat-ci", "redeem")
    assert :ok = Biscuit.parse(minted, pub)

    held = Biscuit.append_holder(minted, pub, "FP")
    assert :ok = Biscuit.authorize(held, pub, "FP", "github-pat-ci", "redeem", true)
    assert {:error, _} = Biscuit.authorize(held, pub, "FP", "github-pat-ci", "redeem", false)

    tampered = :binary.part(minted, 0, byte_size(minted) - 1) <> <<0>>
    assert {:error, _} = Biscuit.parse(tampered, pub)
  end

  describe "recorded hops" do
    setup do
      pair = Biscuit.keypair()
      minted = Biscuit.mint(pair.private_hex, "github-pat-ci", "redeem")
      held = Biscuit.append_holder(minted, pair.public_hex, "FP")
      %{pub: pair.public_hex, minted: minted, held: held}
    end

    test "a holder-bound mint authorizes with zero hop blocks", %{pub: pub, held: held} do
      assert [authority, holder] = block_sources(held, pub)
      assert authority =~ ~s|right("github-pat-ci", "redeem")|
      assert String.trim(holder) == ~s|check if holder($fp), $fp == "FP";|
      assert :ok = Biscuit.authorize(held, pub, "FP", "github-pat-ci", "redeem", true)
      assert {:error, _} = Biscuit.authorize(held, pub, "FP", "github-pat-ci", "redeem", false)
    end

    test "one hop restates only the same check and preserves all earlier blocks", %{
      pub: pub,
      held: held
    } do
      hopped = Biscuit.append_hop(held, pub)
      assert is_binary(hopped)
      earlier = block_sources(held, pub)
      assert block_sources(hopped, pub) == earlier ++ [List.last(earlier)]
      assert :ok = Biscuit.authorize(hopped, pub, "FP", "github-pat-ci", "redeem", true)
      assert {:error, _} = Biscuit.authorize(hopped, pub, "FP", "github-pat-ci", "redeem", false)

      assert {:error, _} =
               Biscuit.authorize(hopped, pub, "WRONG", "github-pat-ci", "redeem", true)

      assert {:error, _} = Biscuit.authorize(hopped, pub, "FP", "other-secret", "redeem", true)
      assert {:error, _} = Biscuit.authorize(hopped, pub, "FP", "github-pat-ci", "write", true)
    end

    test "repeated identical hops remain valid and keep requiring the holder", %{
      pub: pub,
      held: held
    } do
      hopped = held |> Biscuit.append_hop(pub) |> Biscuit.append_hop(pub)
      assert is_binary(hopped)
      [authority, holder] = block_sources(held, pub)
      assert block_sources(hopped, pub) == [authority, holder, holder, holder]
      assert :ok = Biscuit.authorize(hopped, pub, "FP", "github-pat-ci", "redeem", true)
      assert {:error, _} = Biscuit.authorize(hopped, pub, "FP", "github-pat-ci", "redeem", false)
    end

    test "a missing holder check or tampering returns an error and no token", %{
      pub: pub,
      minted: minted,
      held: held
    } do
      assert {:error, _} = Biscuit.append_hop(minted, pub)
      <<first, rest::binary>> = held
      tampered = <<Bitwise.bxor(first, 0xFF), rest::binary>>
      assert {:error, _} = Biscuit.append_hop(tampered, pub)
      assert {:error, _} = Biscuit.append_hop(held, Biscuit.keypair().public_hex)

      # The CLI also fails without emitting a JSON token response.
      request =
        Jason.encode!(%{op: "append_hop", public_hex: pub, biscuit_b64: Base.encode64(minted)})

      assert {"", 1} = System.cmd(Application.fetch_env!(:mjolnir, :biscuit_bin), [request])
    end

    defp block_sources(token, public_hex) do
      request =
        Jason.encode!(%{op: "parse", public_hex: public_hex, biscuit_b64: Base.encode64(token)})

      assert {out, 0} = System.cmd(Application.fetch_env!(:mjolnir, :biscuit_bin), [request])
      assert %{"ok" => true, "blocks" => blocks} = Jason.decode!(out)
      blocks
    end
  end

  describe "durable production authority" do
    setup do
      app_started? = Process.whereis(Mjolnir.Supervisor) != nil

      keys = [
        :biscuit_root_path,
        :biscuit_public_hex,
        :biscuit_bin,
        :btrfs_root,
        :secret_escrow_dir
      ]

      saved = Map.new(keys, &{&1, Application.fetch_env(:mjolnir, &1)})
      cached = :persistent_term.get({Biscuit, :authority}, nil)
      dir = Path.join(System.tmp_dir!(), "biscuit-root-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      root = Path.join(dir, "root")
      pair = Biscuit.keypair()
      File.write!(root, pair.private_hex <> "\n")
      File.chmod!(root, 0o600)
      :persistent_term.erase({Biscuit, :authority})
      Application.put_env(:mjolnir, :biscuit_root_path, root)
      Application.delete_env(:mjolnir, :biscuit_public_hex)
      Application.put_env(:mjolnir, :btrfs_root, Path.join(dir, "btrfs"))
      Application.put_env(:mjolnir, :secret_escrow_dir, Path.join(dir, "escrow"))

      on_exit(fn ->
        :persistent_term.erase({Biscuit, :authority})
        if cached, do: :persistent_term.put({Biscuit, :authority}, cached)

        for {key, value} <- saved do
          case value do
            {:ok, value} -> Application.put_env(:mjolnir, key, value)
            :error -> Application.delete_env(:mjolnir, key)
          end
        end

        File.rm_rf!(dir)

        # Boot-failure checks stop the shared app; restore it after restoring
        # its authority/config so later tests do not inherit a stopped tree.
        if app_started? do
          assert {:ok, _} = Application.ensure_all_started(:mjolnir)
        end
      end)

      %{dir: dir, root: root, pair: pair}
    end

    test "two mints share the cached root and publish the verifier when unset", %{
      root: root,
      pair: pair
    } do
      first = Biscuit.mint_production("secret", "redeem")
      assert Application.fetch_env!(:mjolnir, :biscuit_public_hex) == pair.public_hex
      assert Biscuit.authority() == pair
      File.rm!(root)
      second = Biscuit.mint_production("secret", "redeem")
      assert :ok = Biscuit.parse(first, pair.public_hex)
      assert :ok = Biscuit.parse(second, pair.public_hex)
      refute File.exists?(root)
    end

    test "a fresh OS process reloads the root, verifies an old token, and mints again", %{
      root: root,
      pair: pair
    } do
      token = Biscuit.mint_production("secret", "redeem")
      bin = Application.fetch_env!(:mjolnir, :biscuit_bin)

      code = """
      Application.put_env(:mjolnir, :biscuit_root_path, #{inspect(root)})
      Application.put_env(:mjolnir, :biscuit_bin, #{inspect(bin)})
      Application.put_env(:mjolnir, :btrfs_root, "/nonexistent/btrfs")
      root = Mjolnir.Biscuit.authority()
      true = root.public_hex == #{inspect(pair.public_hex)}
      :ok = Mjolnir.Biscuit.parse(Base.decode64!(#{inspect(Base.encode64(token))}), root.public_hex)
      token = Mjolnir.Biscuit.mint_production("secret", "redeem")
      :ok = Mjolnir.Biscuit.parse(token, root.public_hex)
      IO.puts(Base.encode64(token))
      """

      paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))
      args = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code]
      assert {out, 0} = System.cmd(System.find_executable("elixir"), args, stderr_to_stdout: true)
      assert :ok = Biscuit.parse(Base.decode64!(String.trim(out)), pair.public_hex)
    end

    test "boot fails before starting listeners on a public-key mismatch", %{
      root: root,
      pair: pair
    } do
      stop_app!()
      Application.put_env(:mjolnir, :biscuit_public_hex, String.duplicate("0", 64))
      assert_raise RuntimeError, ~r/disagrees/, fn -> Mjolnir.Application.start(:normal, []) end
      assert :persistent_term.get({Biscuit, :authority}, nil) == nil
      assert File.read!(root) == pair.private_hex <> "\n"
    end

    test "matching configured verifier and a body without newline are accepted", %{
      root: root,
      pair: pair
    } do
      File.write!(root, pair.private_hex)
      Application.put_env(:mjolnir, :biscuit_public_hex, pair.public_hex)
      assert Biscuit.authority() == pair
    end

    test "malformed bodies fail closed without replacement", %{root: root, pair: pair} do
      for body <- [
            "",
            "bad",
            String.upcase(pair.private_hex),
            pair.private_hex <> "\n\n",
            pair.private_hex <> " ",
            String.duplicate("0", 63)
          ] do
        File.write!(root, body)
        assert_raise RuntimeError, fn -> Biscuit.authority() end
        assert File.read!(root) == body
        assert :persistent_term.get({Biscuit, :authority}, nil) == nil
      end
    end

    test "permissions other than exactly 0600 fail without chmod", %{root: root} do
      for mode <- [0o644, 0o400, 0o000] do
        File.chmod!(root, mode)
        assert_raise RuntimeError, fn -> Biscuit.authority() end
        assert Bitwise.band(File.stat!(root).mode, 0o7777) == mode
      end

      # File.chmod only applies rwx bits; use chmod to exercise special bits.
      assert {_, 0} = System.cmd("chmod", ["1600", root])
      assert_raise RuntimeError, fn -> Biscuit.authority() end
      assert Bitwise.band(File.stat!(root).mode, 0o7777) == 0o1600
    end

    test "missing and non-regular roots fail closed without creation", %{root: root, dir: dir} do
      stop_app!()
      File.rm!(root)
      assert_raise RuntimeError, fn -> Mjolnir.Application.start(:normal, []) end
      refute File.exists?(root)
      Application.put_env(:mjolnir, :biscuit_root_path, dir)
      assert_raise RuntimeError, fn -> Biscuit.authority() end
    end

    test "btrfs and escrow paths, including symlinked parents, are forbidden", %{
      dir: dir,
      root: root
    } do
      for boundary <- [
            Application.fetch_env!(:mjolnir, :btrfs_root),
            Application.fetch_env!(:mjolnir, :secret_escrow_dir)
          ] do
        File.mkdir_p!(boundary)
        destination = Path.join(boundary, "root")
        File.cp!(root, destination)
        File.chmod!(destination, 0o600)
        Application.put_env(:mjolnir, :biscuit_root_path, destination)
        assert_raise RuntimeError, ~r/forbidden/, fn -> Biscuit.authority() end
        link = Path.join(dir, "alias")
        File.ln_s!(boundary, link)
        Application.put_env(:mjolnir, :biscuit_root_path, Path.join(link, "root"))
        assert_raise RuntimeError, ~r/forbidden/, fn -> Biscuit.authority() end
        File.rm!(link)
      end

      Application.put_env(:mjolnir, :biscuit_root_path, "/var/lib/mjolnir/escrow/root")
      assert_raise RuntimeError, ~r/forbidden/, fn -> Biscuit.authority() end
    end

    test "explicit-key mint and ephemeral keypair never load the host root", %{
      root: root,
      pair: pair
    } do
      File.rm!(root)

      assert :ok =
               Biscuit.parse(Biscuit.mint(pair.private_hex, "secret", "redeem"), pair.public_hex)

      assert %{private_hex: _, public_hex: _} = Biscuit.keypair()
      assert :persistent_term.get({Biscuit, :authority}, nil) == nil
    end

    test "CLI failure sends private JSON only on stdin and redacts its response", %{
      dir: dir,
      pair: pair
    } do
      bin = Path.join(dir, "failing-cli")
      argv = Path.join(dir, "argv")
      body = Path.join(dir, "body")

      File.write!(bin, """
      #!/bin/sh
      printf '%s\\n' "$@" > '#{argv}'
      cat > '#{body}'
      cat '#{body}' >&2
      exit 19
      """)

      File.chmod!(bin, 0o700)
      Application.put_env(:mjolnir, :biscuit_bin, bin)
      error = assert_raise RuntimeError, fn -> Biscuit.mint_production("secret", "redeem") end
      assert Exception.message(error) == "mjolnir-biscuit failed (exit 19)"
      refute File.read!(argv) =~ pair.private_hex
      assert Jason.decode!(File.read!(body))["private_hex"] == pair.private_hex
      refute Exception.format(:error, error, []) =~ pair.private_hex

      # Even a successful exit echoing the request must not surface the body.
      File.write!(bin, "#!/bin/sh\ncat\n")
      error = assert_raise RuntimeError, fn -> Biscuit.mint_production("secret", "redeem") end
      refute Exception.message(error) =~ pair.private_hex
    end

    # Mix already started the app. `Application.start/2` does not re-enter
    # `start/2` in that case, so a boot assertion has to stop it first.
    defp stop_app! do
      case Application.stop(:mjolnir) do
        :ok -> :ok
        {:error, {:not_started, :mjolnir}} -> :ok
      end
    end
  end
end
