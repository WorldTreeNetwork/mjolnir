defmodule Mjolnir.Sites.MaterializerTest do
  use ExUnit.Case, async: false

  alias Mjolnir.Sites.{Crypto, Manifest, Materializer, Publisher, Store}
  alias Mjolnir.Sites.Manifest.Entry

  @fp "9W3eTrPJoS4R2kXuB6Ny"
  @site "blog"

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("mjolnir-materializer-test-#{System.unique_integer([:positive])}")

    sites_root = Path.join(tmp, "sites")
    materialized = Path.join(tmp, "materialized")
    File.mkdir_p!(Path.join([sites_root, "blob", "b3"]))
    File.mkdir_p!(Path.join([sites_root, "manifests"]))

    original_root = Application.get_env(:mjolnir, :sites_root)
    original_mat = Application.get_env(:mjolnir, :sites_materialized_root)
    Application.put_env(:mjolnir, :sites_root, sites_root)
    Application.put_env(:mjolnir, :sites_materialized_root, materialized)

    on_exit(fn ->
      Application.put_env(:mjolnir, :sites_root, original_root)
      Application.put_env(:mjolnir, :sites_materialized_root, original_mat)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, materialized: materialized}
  end

  # Build a snapshot from a map of "/path" => contents, push manifest + chunks
  # into the Store, and return the snapshot hash.
  defp publish!(files, opts \\ []) do
    src = Path.join(System.tmp_dir!(), "mjolnir-src-#{System.unique_integer([:positive])}")

    Enum.each(files, fn {path, contents} ->
      dest = Path.join(src, String.trim_leading(path, "/"))
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, contents)
    end)

    {manifest, chunks} = Publisher.build_snapshot(src, @fp, @site, opts)
    File.rm_rf!(src)

    store!(manifest, chunks)
  end

  defp store!(manifest, chunks) do
    Enum.each(chunks, fn {hash, %{ciphertext: ct, outboard: ob}} ->
      :ok = Store.put_chunk(hash, ct, ob)
    end)

    bytes = Manifest.serialize(manifest)
    hash = Manifest.snapshot_hash(bytes)
    :ok = Store.put_manifest(hash, bytes)
    hash
  end

  # Build a manifest by hand so a test can put a hostile path in it — the
  # Publisher can only ever produce paths that came off a real filesystem walk.
  defp publish_raw_paths!(paths) do
    sym_seed = Crypto.gen_sym_seed()

    {entries, chunks} =
      Enum.reduce(paths, {[], %{}}, fn {path, contents}, {entries, chunks} ->
        nonce = Crypto.gen_nonce()
        key = Crypto.hkdf_sha256(sym_seed, path, 32)
        ct = Crypto.xchacha20_encrypt(key, nonce, contents)
        hash = Crypto.blake3_hash_base58(ct)

        entry = %Entry{
          path: path,
          content_type: "text/plain; charset=utf-8",
          bao_hash: hash,
          ciphertext_size: byte_size(ct),
          plaintext_size: byte_size(contents),
          nonce: nonce,
          wrapped_key: nil,
          content_encoding: nil
        }

        {[entry | entries], Map.put(chunks, hash, %{ciphertext: ct, outboard: <<>>})}
      end)

    manifest = %Manifest{
      version: 1,
      identikey_fp: @fp,
      site_name: @site,
      mode: :public,
      created_at: DateTime.utc_now() |> DateTime.truncate(:second),
      sym_seed: sym_seed,
      signatures: <<>>,
      entries: Enum.reverse(entries)
    }

    store!(manifest, chunks)
  end

  describe "materialize/4" do
    test "writes plaintext files at their manifest paths" do
      hash =
        publish!(%{
          "/index.html" => "<h1>hello</h1>",
          "/assets/app.css" => "body{}",
          "/nested/deep/data.json" => ~s({"a":1})
        })

      assert {:ok, dir} = Materializer.materialize(@fp, @site, hash)

      assert File.read!(Path.join(dir, "index.html")) == "<h1>hello</h1>"
      assert File.read!(Path.join(dir, "assets/app.css")) == "body{}"
      assert File.read!(Path.join(dir, "nested/deep/data.json")) == ~s({"a":1})
    end

    test "lands under <root>/<fp>/<site>/snapshots/<hash>", %{materialized: materialized} do
      hash = publish!(%{"/index.html" => "hi"})

      assert {:ok, dir} = Materializer.materialize(@fp, @site, hash)
      assert dir == Path.join([materialized, @fp, @site, "snapshots", hash])
    end

    test "points current at the snapshot via a relative symlink" do
      hash = publish!(%{"/index.html" => "hi"})
      {:ok, _dir} = Materializer.materialize(@fp, @site, hash)

      link = Materializer.current_link(@fp, @site)
      assert {:ok, target} = File.read_link(link)
      assert target == Path.join("snapshots", hash)
      assert File.read!(Path.join(link, "index.html")) == "hi"
      assert {:ok, ^hash} = Materializer.current_snapshot(@fp, @site)
    end

    test "flips current to the new snapshot and leaves the old one on disk" do
      first = publish!(%{"/index.html" => "v1"})
      second = publish!(%{"/index.html" => "v2"})

      {:ok, first_dir} = Materializer.materialize(@fp, @site, first)
      {:ok, _} = Materializer.materialize(@fp, @site, second)

      assert {:ok, ^second} = Materializer.current_snapshot(@fp, @site)
      assert File.read!(Path.join(Materializer.current_link(@fp, @site), "index.html")) == "v2"
      # Old snapshot stays materialized — rollback is a symlink flip.
      assert File.read!(Path.join(first_dir, "index.html")) == "v1"
    end

    test "rolling current back to an older snapshot" do
      first = publish!(%{"/index.html" => "v1"})
      second = publish!(%{"/index.html" => "v2"})

      {:ok, _} = Materializer.materialize(@fp, @site, first)
      {:ok, _} = Materializer.materialize(@fp, @site, second)
      {:ok, _} = Materializer.materialize(@fp, @site, first)

      assert {:ok, ^first} = Materializer.current_snapshot(@fp, @site)
      assert File.read!(Path.join(Materializer.current_link(@fp, @site), "index.html")) == "v1"
    end

    test "re-materializing an existing snapshot rebuilds it in place" do
      hash = publish!(%{"/index.html" => "hi"})
      {:ok, dir} = Materializer.materialize(@fp, @site, hash)

      File.rm!(Path.join(dir, "index.html"))
      assert {:ok, ^dir} = Materializer.materialize(@fp, @site, hash)
      assert File.read!(Path.join(dir, "index.html")) == "hi"
    end

    test "leaves no temp directories behind" do
      hash = publish!(%{"/index.html" => "hi"})
      {:ok, _} = Materializer.materialize(@fp, @site, hash)

      tmp_dir = Path.join(Materializer.site_dir(@fp, @site), ".tmp")
      assert {:ok, []} = File.ls(tmp_dir)
    end

    test "rejects a manifest belonging to a different site" do
      hash = publish!(%{"/index.html" => "hi"})
      assert {:error, :manifest_mismatch} = Materializer.materialize(@fp, "other-site", hash)
    end

    test "errors when the snapshot has no manifest" do
      assert {:error, :no_manifest} = Materializer.materialize(@fp, @site, "nosuchsnapshot")
    end

    test "errors and writes nothing when a chunk is missing" do
      {manifest, _chunks} =
        Publisher.build_snapshot(fixture_dir(%{"/index.html" => "hi"}), @fp, @site, [])

      bytes = Manifest.serialize(manifest)
      hash = Manifest.snapshot_hash(bytes)
      :ok = Store.put_manifest(hash, bytes)

      assert {:error, {:chunk_missing, _}} = Materializer.materialize(@fp, @site, hash)
      refute File.exists?(Materializer.snapshot_dir(@fp, @site, hash))
      assert :not_found = Materializer.current_snapshot(@fp, @site)
    end
  end

  describe "path safety" do
    test "safe_relative accepts ordinary manifest paths" do
      assert {:ok, "index.html"} = Materializer.safe_relative("/index.html")
      assert {:ok, "a/b/c.js"} = Materializer.safe_relative("/a/b/c.js")
    end

    test "safe_relative rejects traversal, dots, null bytes and relative paths" do
      assert {:skip, :traversal} = Materializer.safe_relative("/../etc/passwd")
      assert {:skip, :traversal} = Materializer.safe_relative("/a/../../b")
      assert {:skip, :traversal} = Materializer.safe_relative("/a/./b")
      assert {:skip, :traversal} = Materializer.safe_relative("/a\\..\\b")
      assert {:skip, :null_byte} = Materializer.safe_relative("/a\0b")
      assert {:skip, :not_absolute} = Materializer.safe_relative("../escape")
      assert {:skip, :empty_path} = Materializer.safe_relative("/")
    end

    test "traversal entries are skipped and never escape the snapshot dir", %{tmp: tmp} do
      canary = Path.join(tmp, "canary.txt")

      hash =
        publish_raw_paths!(%{
          "/index.html" => "safe",
          "/../../../../../../../../#{canary}" => "PWNED",
          "/a/../../../escape.txt" => "PWNED"
        })

      assert {:ok, dir} = Materializer.materialize(@fp, @site, hash)

      # The safe entry still lands — one hostile path must not take a site down.
      assert File.read!(Path.join(dir, "index.html")) == "safe"
      refute File.exists?(canary)
      refute File.exists?(Path.join(tmp, "escape.txt"))
      assert {:ok, ["index.html"]} = File.ls(dir)
    end
  end

  describe "source-tree symlinks" do
    test "a symlink in the source tree is never published", %{tmp: tmp} do
      secret = Path.join(tmp, "secret.txt")
      File.write!(secret, "TOP SECRET")

      src = Path.join(System.tmp_dir!(), "mjolnir-src-#{System.unique_integer([:positive])}")
      File.mkdir_p!(src)
      File.write!(Path.join(src, "index.html"), "safe")
      File.ln_s!(secret, Path.join(src, "creds.txt"))
      # A symlinked *directory* must not be descended into either.
      File.ln_s!(tmp, Path.join(src, "outside"))

      {manifest, _chunks} = Publisher.build_snapshot(src, @fp, @site, [])
      File.rm_rf!(src)

      paths = Enum.map(manifest.entries, & &1.path)
      assert paths == ["/index.html"]
      refute Enum.any?(paths, &String.contains?(&1, "creds"))
    end

    test "escaping symlink is not readable through the materialized directory", %{tmp: tmp} do
      secret = Path.join(tmp, "secret.txt")
      File.write!(secret, "TOP SECRET")

      src = Path.join(System.tmp_dir!(), "mjolnir-src-#{System.unique_integer([:positive])}")
      File.mkdir_p!(src)
      File.write!(Path.join(src, "index.html"), "safe")
      File.ln_s!(secret, Path.join(src, "creds.txt"))

      {manifest, chunks} = Publisher.build_snapshot(src, @fp, @site, [])
      File.rm_rf!(src)
      hash = store!(manifest, chunks)

      assert {:ok, dir} = Materializer.materialize(@fp, @site, hash)

      # Nothing in the served tree exposes the secret, by name or by content.
      assert File.ls!(dir) == ["index.html"]
      refute File.exists?(Path.join(dir, "creds.txt"))

      current = Materializer.current_link(@fp, @site)
      refute File.exists?(Path.join(current, "creds.txt"))
      assert File.read!(Path.join(current, "index.html")) == "safe"
    end

    test "a failed staging leaves the previous current intact" do
      good = publish!(%{"/index.html" => "good"})
      {:ok, _} = Materializer.materialize(@fp, @site, good)

      {manifest, _chunks} =
        Publisher.build_snapshot(fixture_dir(%{"/index.html" => "poisoned"}), @fp, @site, [])

      bytes = Manifest.serialize(manifest)
      broken = Manifest.snapshot_hash(bytes)
      :ok = Store.put_manifest(broken, bytes)

      assert {:error, {:chunk_missing, _}} = Materializer.materialize(@fp, @site, broken)

      assert {:ok, ^good} = Materializer.current_snapshot(@fp, @site)
      assert File.read!(Path.join(Materializer.current_link(@fp, @site), "index.html")) == "good"
      refute File.exists?(Materializer.snapshot_dir(@fp, @site, broken))
      assert {:ok, []} = File.ls(Path.join(Materializer.site_dir(@fp, @site), ".tmp"))
    end
  end

  describe "precompression" do
    @big String.duplicate("<p>hello world</p>\n", 200)

    test "writes .gz and .br siblings for compressible files" do
      hash = publish!(%{"/index.html" => @big})
      {:ok, dir} = Materializer.materialize(@fp, @site, hash)

      gz = Path.join(dir, "index.html.gz")
      assert File.exists?(gz)
      assert :zlib.gunzip(File.read!(gz)) == @big
      assert File.stat!(gz).size < byte_size(@big)

      br = Path.join(dir, "index.html.br")
      assert File.exists?(br)
      assert {:ok, @big} = :brotli.decode(File.read!(br))
      assert File.stat!(br).size < byte_size(@big)
    end

    test "skips already-compressed types" do
      hash = publish!(%{"/hero.avif" => String.duplicate("x", 5000)})
      {:ok, dir} = Materializer.materialize(@fp, @site, hash)

      refute File.exists?(Path.join(dir, "hero.avif.gz"))
      refute File.exists?(Path.join(dir, "hero.avif.br"))
    end

    test "skips tiny files where compression is not worth it" do
      hash = publish!(%{"/small.css" => "body{}"})
      {:ok, dir} = Materializer.materialize(@fp, @site, hash)

      refute File.exists?(Path.join(dir, "small.css.gz"))
      refute File.exists?(Path.join(dir, "small.css.br"))
    end
  end

  describe "retention" do
    test "keeps the last N snapshots and never prunes current" do
      hashes =
        for i <- 1..5 do
          hash = publish!(%{"/index.html" => "v#{i}"})
          {:ok, _} = Materializer.materialize(@fp, @site, hash, prune: false)
          # mtimes are second-granular; stagger so retention order is unambiguous.
          File.touch!(Materializer.snapshot_dir(@fp, @site, hash), 1_700_000_000 + i)
          hash
        end

      :ok = Materializer.prune(@fp, @site, retention: 3)

      snapshots = Path.join(Materializer.site_dir(@fp, @site), "snapshots")
      kept = File.ls!(snapshots) |> Enum.sort()

      assert length(kept) == 3
      assert Enum.sort(Enum.take(hashes, -3)) == kept

      current = List.last(hashes)
      assert {:ok, ^current} = Materializer.current_snapshot(@fp, @site)
      assert current in kept
    end

    test "retention of 1 keeps only current" do
      first = publish!(%{"/index.html" => "v1"})
      second = publish!(%{"/index.html" => "v2"})

      {:ok, _} = Materializer.materialize(@fp, @site, first, retention: 1)
      {:ok, _} = Materializer.materialize(@fp, @site, second, retention: 1)

      snapshots = Path.join(Materializer.site_dir(@fp, @site), "snapshots")
      assert File.ls!(snapshots) == [second]
    end

    test "prune: false leaves everything on disk" do
      hashes =
        for i <- 1..4 do
          hash = publish!(%{"/index.html" => "v#{i}"})
          {:ok, _} = Materializer.materialize(@fp, @site, hash, prune: false)
          hash
        end

      snapshots = Path.join(Materializer.site_dir(@fp, @site), "snapshots")
      assert Enum.sort(File.ls!(snapshots)) == Enum.sort(hashes)
    end
  end

  defp fixture_dir(files) do
    src = Path.join(System.tmp_dir!(), "mjolnir-src-#{System.unique_integer([:positive])}")

    Enum.each(files, fn {path, contents} ->
      dest = Path.join(src, String.trim_leading(path, "/"))
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, contents)
    end)

    on_exit(fn -> File.rm_rf!(src) end)
    src
  end
end
