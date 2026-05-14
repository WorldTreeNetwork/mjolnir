defmodule Mix.Tasks.Mjolnir.Sites.Alias do
  @shortdoc "Add or remove a custom-domain alias for an IdentiKey site"

  @moduledoc """
  Manage custom-domain (vanity) aliases for IdentiKey-owned static sites.

  ## Usage

      mix mjolnir.sites.alias add <fqdn> \\
        --identikey-fp <fp> \\
        --site <name> \\
        --keypair-file <path> \\
        --base-url http://localhost:4000 \\
        [--sequence N]

      mix mjolnir.sites.alias remove <fqdn> \\
        --identikey-fp <fp> \\
        --site <name> \\
        --keypair-file <path> \\
        --base-url http://localhost:4000 \\
        [--sequence N]

  ## Options

    * `add|remove` — subcommand (required)
    * `<fqdn>` — fully-qualified domain name to alias, e.g. `blog.duke.io` (required)
    * `--identikey-fp` — base58 fingerprint of the IdentiKey (required)
    * `--site` — site name, e.g. `blog` (required)
    * `--keypair-file` — path to a JSON keypair file produced by
      `Sites.IdentiKey.keypair_to_json/1` (required)
    * `--base-url` — base URL of the Mjolnir host API, e.g. `http://localhost:4000` (required)
    * `--sequence` — alias sequence number (default: 1 for add, unix-ms for remove)

  ## Example

      mix mjolnir.sites.alias add blog.duke.io \\
        --identikey-fp 9W3eTrPJoS4R2kXuB6Ny \\
        --site blog \\
        --keypair-file /path/to/keypair.json \\
        --base-url http://localhost:4000
  """

  use Mix.Task

  alias Mjolnir.Sites.{IdentiKey, Publisher}

  @switches [
    identikey_fp: :string,
    site: :string,
    keypair_file: :string,
    base_url: :string,
    sequence: :integer
  ]

  @aliases [
    f: :identikey_fp,
    s: :site,
    k: :keypair_file,
    u: :base_url,
    n: :sequence
  ]

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:req)

    {opts, positional, _invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    {subcmd, fqdn} =
      case positional do
        [cmd, fqdn | _] when cmd in ["add", "remove"] -> {cmd, fqdn}
        [cmd | _] when cmd in ["add", "remove"] ->
          Mix.raise("mjolnir.sites.alias: <fqdn> argument is required")
        _ ->
          Mix.raise("mjolnir.sites.alias: subcommand must be 'add' or 'remove'")
      end

    fp = Keyword.get(opts, :identikey_fp) ||
      Mix.raise("mjolnir.sites.alias: --identikey-fp is required")
    site = Keyword.get(opts, :site) ||
      Mix.raise("mjolnir.sites.alias: --site is required")
    keypair_file = Keyword.get(opts, :keypair_file) ||
      Mix.raise("mjolnir.sites.alias: --keypair-file is required")
    base_url = Keyword.get(opts, :base_url) ||
      Mix.raise("mjolnir.sites.alias: --base-url is required")

    unless File.exists?(keypair_file) do
      Mix.raise("mjolnir.sites.alias: keypair file #{inspect(keypair_file)} not found")
    end

    keypair =
      case IdentiKey.keypair_from_json(File.read!(keypair_file)) do
        {:ok, kp} -> kp
        {:error, reason} -> Mix.raise("mjolnir.sites.alias: failed to load keypair: #{inspect(reason)}")
      end

    case subcmd do
      "add" ->
        sequence = Keyword.get(opts, :sequence, 1)
        Mix.shell().info("Adding alias #{fqdn} → #{base_url}/api/sites/#{fp}/#{site} (sequence=#{sequence})")

        case Publisher.publish_alias(keypair, fp, site, fqdn, base_url, sequence: sequence) do
          {:ok, _body} ->
            Mix.shell().info("""

            Alias added successfully.
              FQDN     : #{fqdn}
              Site     : #{site}
              Sequence : #{sequence}
            """)

          {:error, reason} ->
            Mix.raise("mjolnir.sites.alias add failed: #{inspect(reason)}")
        end

      "remove" ->
        sequence = Keyword.get(opts, :sequence, :erlang.system_time(:millisecond))
        Mix.shell().info("Removing alias #{fqdn} from #{base_url}/api/sites/#{fp}/#{site}")

        case Publisher.remove_alias(keypair, fp, site, fqdn, base_url, sequence: sequence) do
          :ok ->
            Mix.shell().info("""

            Alias removed successfully.
              FQDN : #{fqdn}
            """)

          {:error, reason} ->
            Mix.raise("mjolnir.sites.alias remove failed: #{inspect(reason)}")
        end
    end
  end
end
