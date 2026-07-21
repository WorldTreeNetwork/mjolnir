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
      {:hackney, "~> 1.20"},
      {:jason, "~> 1.4"},
      {:joken, "~> 2.6"},
      {:joken_jwks, "~> 1.7"},
      {:plug, "~> 1.16"},
      {:postgrex, "~> 0.19"},
      {:req, "~> 0.4"},
      {:typed_struct, "~> 0.3"},
      {:uuid, "~> 1.1"},
      {:websock_adapter, "~> 0.5"},
      {:ex_mcp, "~> 0.7"}
      # Blake3 NIF (`:blake3`) was tried but its rustler 0.30 binding doesn't
      # compile on current Rust, and the 0.37+ binding has a cargo
      # disambiguation bug. `Mjolnir.Sites.Crypto.blake3_hash/1` currently uses
      # SHA-256 as a same-shape placeholder; real Blake3 will land via the
      # recrypt Rust integration when that's wired.
    ]
  end
end
