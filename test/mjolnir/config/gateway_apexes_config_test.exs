defmodule Mjolnir.Config.GatewayApexesConfigTest do
  @moduledoc """
  Exercises the MJOLNIR_GATEWAY_APEXES parse/merge in config/runtime.exs
  (gge.12.3) by evaluating the real runtime config file with the env var set.
  Not async: it mutates the process environment.
  """
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../../config/runtime.exs", __DIR__)

  # Evaluate config/runtime.exs and return the :gateway_apexes it produced (or
  # nil when it left the key alone — i.e. the compile-time default stands).
  defp apexes_from_runtime do
    Config.Reader.read!(@runtime_config, env: :test)
    |> get_in([:mjolnir, :gateway_apexes])
  end

  setup do
    prev = System.get_env("MJOLNIR_GATEWAY_APEXES")

    on_exit(fn ->
      if prev,
        do: System.put_env("MJOLNIR_GATEWAY_APEXES", prev),
        else: System.delete_env("MJOLNIR_GATEWAY_APEXES")
    end)

    :ok
  end

  test "unset env var leaves gateway_apexes untouched (compile-time default stands)" do
    System.delete_env("MJOLNIR_GATEWAY_APEXES")
    assert apexes_from_runtime() == nil
  end

  test "merges parsed apexes onto the compile-time defaults, defaults first, deduped" do
    System.put_env("MJOLNIR_GATEWAY_APEXES", "customer.com, identikey.io , other.dev")

    apexes = apexes_from_runtime()
    defaults = Application.get_env(:mjolnir, :gateway_apexes)

    # Defaults preserved and ordered first.
    assert Enum.take(apexes, length(defaults)) == defaults
    # New apexes appended.
    assert "customer.com" in apexes
    assert "other.dev" in apexes
    # Whitespace trimmed and duplicates (identikey.io is a default) collapsed.
    assert Enum.count(apexes, &(&1 == "identikey.io")) == 1
    assert apexes == Enum.uniq(apexes)
  end

  test "empty / whitespace-only entries yield a list identical to the defaults" do
    System.put_env("MJOLNIR_GATEWAY_APEXES", " , ,")
    assert apexes_from_runtime() == Application.get_env(:mjolnir, :gateway_apexes)
  end
end
