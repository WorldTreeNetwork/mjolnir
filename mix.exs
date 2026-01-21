defmodule Mjolnir.MixProject do
  use Mix.Project

  def project do
    [
      app: :mjolnir,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
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
      {:jason, "~> 1.4"},
      {:req, "~> 0.4"},
      {:typed_struct, "~> 0.3"},
      {:uuid, "~> 1.1"}
    ]
  end
end
