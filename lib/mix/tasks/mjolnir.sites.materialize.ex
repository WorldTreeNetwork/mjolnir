defmodule Mix.Tasks.Mjolnir.Sites.Materialize do
  @shortdoc "Materialize a published snapshot into a plaintext directory tree"

  @moduledoc """
  Rebuilds the plaintext directory a static file server serves for a site, from
  the signed manifest plus the chunk store.

  Use this to backfill sites published before materialization existed, or to
  rebuild a tree that was deleted — the materialized directory is a derived
  cache, never a source of truth.

  ## Usage

      mix mjolnir.sites.materialize \\
        --identikey-fp <fp> \\
        --site <name> \\
        [--snapshot <hash>] \\
        [--retention <n>]

  ## Options

    * `--identikey-fp` — base58 fingerprint of the publishing IdentiKey (required)
    * `--site` — site name, e.g. `blog` (required)
    * `--snapshot` — snapshot hash to materialize (default: whatever the site's
      current HEAD record points at). Pass an older hash to roll back — the
      `current` symlink is flipped to whatever is materialized.
    * `--retention` — how many snapshot directories to keep (default:
      `:sites_snapshot_retention`)

  ## Example

      mix mjolnir.sites.materialize -f 9W3eTrPJoS4R2kXuB6Ny -s blog

  This task runs against the local node's configured `:sites_root` /
  `:sites_materialized_root`, so it must run on the Mjolnir host.
  """

  use Mix.Task

  alias Mjolnir.Sites.Materializer

  @switches [
    identikey_fp: :string,
    site: :string,
    snapshot: :string,
    retention: :integer
  ]

  @aliases [
    f: :identikey_fp,
    s: :site,
    h: :snapshot,
    r: :retention
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, _invalid} =
      OptionParser.parse(args, switches: @switches, aliases: @aliases)

    fp =
      Keyword.get(opts, :identikey_fp) ||
        Mix.raise("mjolnir.sites.materialize: --identikey-fp is required")

    site = Keyword.get(opts, :site) || Mix.raise("mjolnir.sites.materialize: --site is required")

    materialize_opts =
      case Keyword.get(opts, :retention) do
        nil -> []
        n -> [retention: n]
      end

    result =
      case Keyword.get(opts, :snapshot) do
        nil -> Materializer.materialize_head(fp, site, materialize_opts)
        hash -> Materializer.materialize(fp, site, hash, materialize_opts)
      end

    case result do
      {:ok, dir} ->
        Mix.shell().info("""

        Materialized.
          Snapshot dir : #{dir}
          current      : #{Materializer.current_link(fp, site)}
        """)

      {:error, reason} ->
        Mix.raise("mjolnir.sites.materialize failed: #{inspect(reason)}")
    end
  end
end
