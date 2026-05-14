defmodule Mix.Tasks.Mjolnir.Sites.Publish do
  @shortdoc "Publish a local directory as a public-mode IdentiKey site"

  @moduledoc """
  Encrypts and uploads a local directory as an IdentiKey-owned static site.

  ## Usage

      mix mjolnir.sites.publish <directory> \\
        --identikey-fp <fp> \\
        --site <name> \\
        --base-url http://localhost:4000 \\
        --keypair-file <path> \\
        [--sequence <n>]

  ## Options

    * `--identikey-fp` — base58 fingerprint of the publishing IdentiKey (required)
    * `--site` — site name, e.g. `blog` (required)
    * `--base-url` — base URL of the Mjolnir host API, e.g. `http://localhost:4000` (required)
    * `--keypair-file` — path to a JSON keypair file (as produced by
      `Mjolnir.Sites.IdentiKey.keypair_to_json/1`). When provided, manifests
      and HEAD records are signed with the keypair's ED25519 secret. Required
      for any host whose SecretStore enforces signature verification (the
      default in Phase 1+).
    * `--sequence` — HEAD sequence number for this publish (default: 1); must be
      strictly greater than the current HEAD sequence on the server

  ## Publishing flow

  1. Walks `<directory>` recursively, collecting all regular files.
  2. Generates a per-snapshot `sym_seed` (32 bytes random).
  3. For each file: derives a per-file symmetric key via
     `HKDF-SHA256(sym_seed, info=file_path, 32)`, encrypts with XChaCha20, and
     computes the ciphertext Blake3 hash (`bao_hash`).
  4. Builds a signed `Manifest` (signatures are a placeholder in Phase 1 — see
     `Mjolnir.Sites.Publisher`).
  5. POSTs the manifest to `<base_url>/api/sites/<fp>/<site>/snapshot`.
  6. Uploads any missing chunks to `<base_url>/api/sites/blob/<bao_hash>`.
  7. POSTs a HEAD record to `<base_url>/api/sites/<fp>/<site>/head`.
  8. Prints a summary.

  ## Example

      mix mjolnir.sites.publish ./public \\
        --identikey-fp 9W3eTrPJoS4R2kXuB6Ny \\
        --site blog \\
        --base-url http://localhost:4000

  """

  use Mix.Task

  alias Mjolnir.Sites.{IdentiKey, Publisher}

  @switches [
    identikey_fp: :string,
    site: :string,
    base_url: :string,
    sequence: :integer,
    keypair_file: :string
  ]

  @aliases [
    f: :identikey_fp,
    s: :site,
    u: :base_url,
    n: :sequence,
    k: :keypair_file
  ]

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:req)

    {opts, positional, _invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    dir =
      case positional do
        [d | _] -> d
        [] -> Mix.raise("mjolnir.sites.publish: <directory> argument is required")
      end

    fp = Keyword.get(opts, :identikey_fp) || Mix.raise("mjolnir.sites.publish: --identikey-fp is required")
    site = Keyword.get(opts, :site) || Mix.raise("mjolnir.sites.publish: --site is required")
    base_url = Keyword.get(opts, :base_url) || Mix.raise("mjolnir.sites.publish: --base-url is required")
    sequence = Keyword.get(opts, :sequence, 1)
    keypair = load_keypair(Keyword.get(opts, :keypair_file))

    unless File.dir?(dir) do
      Mix.raise("mjolnir.sites.publish: #{inspect(dir)} is not a directory")
    end

    Mix.shell().info("Publishing #{dir} → #{base_url}/api/sites/#{fp}/#{site} (sequence=#{sequence})")

    publish_opts =
      [sequence: sequence]
      |> then(fn opts -> if keypair, do: Keyword.put(opts, :keypair, keypair), else: opts end)

    case Publisher.publish(dir, fp, site, base_url, publish_opts) do
      {:ok, %{snapshot_hash: hash, sequence: seq}} ->
        Mix.shell().info("""

        Published successfully.
          Snapshot hash : #{hash}
          Sequence      : #{seq}
          Serve URL     : #{base_url}/api/sites/#{fp}/#{site}/files/
        """)

      {:error, reason} ->
        Mix.raise("mjolnir.sites.publish failed: #{inspect(reason)}")
    end
  end

  defp load_keypair(nil), do: nil

  defp load_keypair(path) do
    case File.read(path) do
      {:ok, json} ->
        case IdentiKey.keypair_from_json(json) do
          {:ok, kp} ->
            kp

          {:error, reason} ->
            Mix.raise("mjolnir.sites.publish: invalid keypair file #{path}: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("mjolnir.sites.publish: cannot read keypair file #{path}: #{inspect(reason)}")
    end
  end
end
