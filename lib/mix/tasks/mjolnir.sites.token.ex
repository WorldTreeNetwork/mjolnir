defmodule Mix.Tasks.Mjolnir.Sites.Token do
  @shortdoc "Mint, list, and revoke scoped Sites publishing tokens"

  @moduledoc """
  Operator management of `Mjolnir.Sites.Token` service credentials.

  These are the credentials an unattended publisher (a Forgejo CI runner) uses
  to publish a site. They grant `sites:publish` and nothing else — never
  `vms:*`, `snapshots:*`, `pty:*` or `terminal:*` — and are bound to one
  IdentiKey fingerprint, optionally to one site.

  This task reads and writes the local node's token store, so it must run on the
  Mjolnir host.

  ## Usage

      mix mjolnir.sites.token create --identikey-fp <fp> [--site <name>] \\
        [--expires-in <duration>] [--description <text>]
      mix mjolnir.sites.token list [--all]
      mix mjolnir.sites.token revoke <token-id>

  ## Options

    * `--identikey-fp` / `-f` — fingerprint the token may publish under (required)
    * `--site` / `-s` — restrict to a single site name (default: any site under
      that fingerprint)
    * `--expires-in` / `-e` — lifetime, e.g. `90d`, `12h`, `30m` (default: no
      expiry). Prefer setting one.
    * `--description` — free text shown by `list`, e.g. "forgejo ci worldtree"
    * `--all` — `list` also shows revoked and expired tokens

  ## The secret is shown once

  `create` prints the credential exactly once. Only its SHA-256 is stored, so a
  lost token cannot be recovered — revoke it and mint another.

  ## Example

      mix mjolnir.sites.token create -f 9W3eTrPJoS4R2kXuB6Ny -s blog -e 90d \\
        --description "forgejo ci"

      mix mjolnir.sites.token revoke 3f9a2b1c8d7e6f50
  """

  use Mix.Task

  alias Mjolnir.Sites.{Token, TokenStore}

  @switches [
    identikey_fp: :string,
    site: :string,
    expires_in: :string,
    description: :string,
    all: :boolean
  ]

  @aliases [f: :identikey_fp, s: :site, e: :expires_in]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _invalid} =
      OptionParser.parse(args, switches: @switches, aliases: @aliases)

    case positional do
      ["create" | _] -> create(opts)
      ["list" | _] -> list(opts)
      ["revoke", id | _] -> revoke(id)
      ["revoke"] -> Mix.raise("mjolnir.sites.token revoke: <token-id> is required")
      other -> Mix.raise("mjolnir.sites.token: unknown command #{inspect(other)}")
    end
  end

  defp create(opts) do
    fp =
      Keyword.get(opts, :identikey_fp) ||
        Mix.raise("mjolnir.sites.token create: --identikey-fp is required")

    expires_at =
      case Keyword.get(opts, :expires_in) do
        nil -> nil
        duration -> DateTime.add(DateTime.utc_now(), parse_duration!(duration), :second)
      end

    create_opts = [
      site_name: Keyword.get(opts, :site),
      description: Keyword.get(opts, :description),
      expires_at: expires_at && DateTime.truncate(expires_at, :second)
    ]

    case TokenStore.create(fp, create_opts) do
      {:ok, token, plaintext} ->
        Mix.shell().info("""

        Token created. This is the only time the secret is shown.

          Token       : #{plaintext}
          Id          : #{token.id}
          Fingerprint : #{token.identikey_fp}
          Site        : #{token.site_name || "(any site under this fingerprint)"}
          Expires     : #{token.expires_at || "never"}
          Scope       : #{Token.scope()}

        Send it as:

          Authorization: Bearer #{plaintext}

        Revoke with: mix mjolnir.sites.token revoke #{token.id}
        """)

      {:error, reason} ->
        Mix.raise("mjolnir.sites.token create failed: #{inspect(reason)}")
    end
  end

  defp list(opts) do
    show_all? = Keyword.get(opts, :all, false)
    now = DateTime.utc_now()

    tokens =
      TokenStore.list()
      |> Enum.reject(fn t ->
        not show_all? and (Token.revoked?(t) or Token.expired?(t, now))
      end)

    if tokens == [] do
      Mix.shell().info("No tokens." <> if(show_all?, do: "", else: " (try --all)"))
    else
      Mix.shell().info("")

      Enum.each(tokens, fn t ->
        Mix.shell().info("""
        #{t.id}  #{status(t, now)}
          fingerprint : #{t.identikey_fp}
          site        : #{t.site_name || "(any)"}
          created     : #{t.created_at}
          expires     : #{t.expires_at || "never"}
          description : #{t.description || "-"}
        """)
      end)
    end
  end

  defp revoke(id) do
    case TokenStore.revoke(id) do
      :ok -> Mix.shell().info("Revoked #{id}.")
      :not_found -> Mix.raise("mjolnir.sites.token revoke: no token with id #{id}")
      {:error, reason} -> Mix.raise("mjolnir.sites.token revoke failed: #{inspect(reason)}")
    end
  end

  defp status(token, now) do
    cond do
      Token.revoked?(token) -> "[REVOKED #{token.revoked_at}]"
      Token.expired?(token, now) -> "[EXPIRED]"
      true -> "[active]"
    end
  end

  @doc false
  # Accepts `<integer><unit>` where unit is s/m/h/d. Returns seconds.
  def parse_duration!(duration) do
    case Regex.run(~r/^(\d+)([smhd])$/, duration) do
      [_, n, unit] ->
        String.to_integer(n) * unit_seconds(unit)

      _ ->
        Mix.raise(
          "mjolnir.sites.token: bad --expires-in #{inspect(duration)}; " <>
            "expected <n><s|m|h|d>, e.g. 90d"
        )
    end
  end

  defp unit_seconds("s"), do: 1
  defp unit_seconds("m"), do: 60
  defp unit_seconds("h"), do: 3600
  defp unit_seconds("d"), do: 86_400
end
