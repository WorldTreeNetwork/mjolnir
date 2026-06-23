defmodule Mix.Tasks.Mjolnir.Publish do
  @shortdoc "Publish a directory as a public site, verifiably from your IdentiKey"

  @moduledoc """
  Publish a static directory to a Mjolnir host — public by default, signed by
  your IdentiKey, addressable by a URL.

  The common case needs no flags and no special vocabulary:

      mix mjolnir.publish ./dist

  On first run this creates an IdentiKey for you (an ED25519 keypair) under
  `~/.config/mjolnir/identikey.json` and prints its fingerprint. Every publish
  is signed with it, so anyone can verify the content came from you.

  ## Options (all optional)

    * `--site` — site name (default: the directory's basename, e.g. `dist`)
    * `--base-url` — Mjolnir host API (default: `http://localhost:<api_port>`)
    * `--identity` — path to an IdentiKey JSON file (default:
      `~/.config/mjolnir/identikey.json`, created on first use)
    * `--sequence` — HEAD sequence for this publish (default: 1; must exceed the
      current HEAD sequence on the host)
    * `--public` — publish openly (this is the default)
    * `--to` — publish to specific recipients *(not yet available — mjolnir-9bq.5)*
    * `--keyspace` — publish to a keyspace/group *(not yet available — mjolnir-9bq.5)*

  `--public`, `--to`, and `--keyspace` are mutually exclusive disclosure modes.
  Only `--public` is implemented today; the encrypted modes route through the
  recrypt keyspace seam (`mjolnir-9bq.5`) and will reuse this same command.

  This is a thin, friendly wrapper over `mix mjolnir.sites.publish`; that task
  remains available for scripting with explicit fingerprints.
  """

  use Mix.Task

  alias Mjolnir.Sites.{IdentiKey, Publisher}

  @switches [
    site: :string,
    base_url: :string,
    identity: :string,
    sequence: :integer,
    public: :boolean,
    to: :string,
    keyspace: :string
  ]

  @aliases [s: :site, u: :base_url, i: :identity, n: :sequence]

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:req)

    {opts, positional, _invalid} =
      OptionParser.parse(args, switches: @switches, aliases: @aliases)

    dir = positional_dir(positional)
    ensure_directory!(dir)
    ensure_public_mode!(opts)

    {keypair, identity_path, created?} = resolve_identity(Keyword.get(opts, :identity))
    fp = IdentiKey.fingerprint(keypair)

    site = Keyword.get(opts, :site) || default_site(dir)
    base_url = Keyword.get(opts, :base_url) || default_base_url()
    sequence = Keyword.get(opts, :sequence, 1)

    if created? do
      Mix.shell().info("""
      Created your IdentiKey → #{identity_path}
        fingerprint: #{fp}
      Keep this file safe — it is your publishing identity.
      """)
    end

    Mix.shell().info("Publishing #{dir} as \"#{site}\" → #{base_url} (signed by #{fp})")

    case Publisher.publish(dir, fp, site, base_url, sequence: sequence, keypair: keypair) do
      {:ok, %{snapshot_hash: hash, sequence: seq}} ->
        Mix.shell().info("""

        Published. Verifiably yours.
          URL       : #{base_url}/api/sites/#{fp}/#{site}/files/
          Snapshot  : #{hash}
          Sequence  : #{seq}
          Signed by : #{fp}
        """)

      {:error, reason} ->
        Mix.raise("mjolnir.publish failed: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Argument resolution (kept as small pure-ish helpers for testability)
  # ---------------------------------------------------------------------------

  defp positional_dir([d | _]), do: d
  defp positional_dir([]), do: Mix.raise("mjolnir.publish: a <directory> argument is required")

  defp ensure_directory!(dir) do
    unless File.dir?(dir) do
      Mix.raise("mjolnir.publish: #{inspect(dir)} is not a directory")
    end
  end

  # Only public mode is implemented. Reject the encrypted modes loudly rather
  # than silently publishing them as public (which would leak content).
  defp ensure_public_mode!(opts) do
    cond do
      Keyword.has_key?(opts, :to) ->
        Mix.raise(
          "mjolnir.publish: --to (recipient publishing) is not available yet. " <>
            "It is tracked by the keyspace seam (mjolnir-9bq.5). Use --public for now."
        )

      Keyword.has_key?(opts, :keyspace) ->
        Mix.raise(
          "mjolnir.publish: --keyspace (group publishing) is not available yet. " <>
            "It is tracked by the keyspace seam (mjolnir-9bq.5). Use --public for now."
        )

      true ->
        :ok
    end
  end

  @doc false
  def default_site(dir), do: dir |> Path.expand() |> Path.basename()

  @doc false
  def default_base_url do
    port = Application.get_env(:mjolnir, :api_port, 4000)
    "http://localhost:#{port}"
  end

  @doc false
  def default_identity_path do
    Path.expand("~/.config/mjolnir/identikey.json")
  end

  # Returns `{keypair, path, created?}`. Loads an existing identity, or
  # generates and persists a new one on first use.
  defp resolve_identity(explicit_path) do
    path = explicit_path || default_identity_path()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, json} ->
          case IdentiKey.keypair_from_json(json) do
            {:ok, kp} ->
              {kp, path, false}

            {:error, reason} ->
              Mix.raise("mjolnir.publish: invalid identity file #{path}: #{inspect(reason)}")
          end

        {:error, reason} ->
          Mix.raise("mjolnir.publish: cannot read identity file #{path}: #{inspect(reason)}")
      end
    else
      keypair = IdentiKey.gen_keypair()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, IdentiKey.keypair_to_json(keypair))
      File.chmod(path, 0o600)
      {keypair, path, true}
    end
  end
end
