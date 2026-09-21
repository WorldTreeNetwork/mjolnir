defmodule Mjolnir.MixProject do
  use Mix.Project

  def project do
    [
      app: :mjolnir,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases()
    ]
  end

  defp releases do
    [
      mjolnir: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Mjolnir.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.6"},
      # Brotli NIF — used by Mjolnir.Sites.Materializer to write `.br` siblings
      # at publish time so the gateway never compresses per request. Optional at
      # runtime: the materializer falls back to gzip-only if it is not loaded.
      {:brotli, "~> 0.3.3"},
      {:ecto, "~> 3.12"},
      {:ecto_sql, "~> 3.12"},
      # NOTE: `:hackney` was a direct dep until mjolnir-ctv. Nothing called it —
      # it is an *optional* Tesla adapter, and no `config :tesla, :adapter` was
      # ever written, so Tesla (via joken_jwks) has always used its httpc
      # default. Meanwhile hackney 1.25 carried 4 open CVEs and the fixed line
      # is 4.x, which joken_jwks 1.7's optional `~> 1.18` constraint forbids.
      # Dropping the unused dep resolves all four rather than pinning to a
      # vulnerable version. Re-add as `~> 4.x` only alongside an explicit
      # Tesla adapter config and a joken_jwks that permits it.
      {:jason, "~> 1.4"},
      {:joken, "~> 2.6"},
      # Direct because Mjolnir.Auth.KeycloakStrategy names Tesla.Adapter.Mint
      # as the JWKS http_adapter (see that module). Both arrive transitively
      # under Req today, but the JWKS path breaks at boot — not at compile —
      # if they ever stop doing so, and castore is what makes Mint verify certs.
      {:castore, "~> 1.0"},
      {:mint, "~> 1.9"},
      {:joken_jwks, "~> 1.7"},
      {:plug, "~> 1.16"},
      {:postgrex, "~> 0.19"},
      {:req, "~> 0.4"},
      # Parses `mjolnir.toml`, the explicit deploy manifest (Deploy.Manifest).
      # Already present transitively; declared here because we depend on it
      # directly and a transitive dep can vanish when its parent changes.
      {:toml, "~> 0.7"},
      {:typed_struct, "~> 0.3"},
      {:uuid, "~> 1.1"},
      {:websock_adapter, "~> 0.5"},
      # Held at 0.7.x deliberately (mjolnir-ctv): `~> 0.7` let the CVE sweep
      # drag in 0.12.0 — five minor versions of a young library, none of it
      # required, since ex_mcp carries no advisories. Widen this as its own
      # change with the MCP tests actually exercised, not as a side effect of
      # a security bump. (Note both 0.7.4 and 0.12.0 declare `elixir: "~> 1.17"`
      # while we build on 1.16; that warning is pre-existing either way.)
      {:ex_mcp, "~> 0.7.4"}
      # Blake3 is `mjolnir-b3` (native/mjolnir_blob_door), not the rustler
      # `:blake3` NIF. Fingerprints stay SHA-256 as minted.
    ]
  end
end
