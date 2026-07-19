defmodule Mjolnir.Health.CorroborationTest do
  @moduledoc """
  Unit tests for the `:dead` corroboration step in `Mjolnir.Health` — the fix
  for false "DEAD" verdicts when only the vsock guest-agent channel is wedged.
  Exercises `corroborated_overall/3` directly with an injected liveness probe,
  so no real VM, vsock, or socket is involved.
  """
  use ExUnit.Case, async: true

  alias Mjolnir.Health

  defp vm, do: struct!(%Mjolnir.VM{id: "vm-1"}, net_config: %{guest_ip: "10.200.0.9"})

  defp liveness(result), do: [liveness: fn _vm, _opts -> result end]

  describe "corroborated_overall/3 — only :dead is corroborated" do
    test ":dead + TCP :alive => downgraded to :agent_unreachable" do
      assert Health.corroborated_overall(:dead, vm(), liveness(:alive)) == :agent_unreachable
    end

    test ":dead + TCP :unreachable => stays :dead" do
      assert Health.corroborated_overall(:dead, vm(), liveness(:unreachable)) == :dead
    end

    test ":dead + TCP :unknown (no corroboration possible) => stays :dead" do
      assert Health.corroborated_overall(:dead, vm(), liveness(:unknown)) == :dead
    end

    test ":ok passes through without probing liveness" do
      exploding = [liveness: fn _vm, _opts -> flunk("liveness must not run for :ok") end]
      assert Health.corroborated_overall(:ok, vm(), exploding) == :ok
    end

    test ":degraded passes through without probing liveness" do
      exploding = [liveness: fn _vm, _opts -> flunk("liveness must not run for :degraded") end]
      assert Health.corroborated_overall(:degraded, vm(), exploding) == :degraded
    end
  end
end
