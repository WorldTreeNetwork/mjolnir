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
      {:hackney, "~> 1.20"},
      {:jason, "~> 1.4"},
      {:joken, "~> 2.6"},
      {:joken_jwks, "~> 1.7"},
      {:plug, "~> 1.16"},
      {:req, "~> 0.4"},
      {:typed_struct, "~> 0.3"},
      {:uuid, "~> 1.1"},
      {:websock_adapter, "~> 0.5"},
      {:ex_mcp, "~> 0.7"}
    ]
  end
end
