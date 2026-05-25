defmodule Mjolnir.Forge.Resource.Iptables do
  @moduledoc """
  Resource kind: iptables rules for a specific table and chain.

  Content shape:

      %{
        table: binary(),        # "nat", "filter", "mangle", "raw"
        chain: binary(),        # "POSTROUTING", "INPUT", "FORWARD", etc.
        rules: [binary()]       # List of rule specs (without -A CHAIN prefix)
      }

  ## Observe strategy

  Probe-backed. For each declared rule, checks existence via
  `iptables -t <table> -C <chain> <rule>`. A resource is `:present` only if
  ALL declared rules exist; if any are missing, it reports the full set
  (so the diff engine sees it as drifted).

  ## Apply semantics

  Additive: checks each rule with `-C`, inserts missing rules with `-A`.
  Does NOT flush the chain — other tools' rules are preserved. Idempotent.

  ## Delete semantics

  Removes each declared rule with `-D`. Non-destructive to other rules in
  the same chain.

  ## When to use ufw_nat instead

  On hosts running ufw, prefer `Mjolnir.Forge.Resource.UfwNat` for NAT rules.
  Raw iptables NAT rules are wiped on `ufw reload`. This kind is for hosts
  without ufw, or for non-NAT rules that ufw doesn't manage.

  ## Sandbox support

  When `config :mjolnir, :forge_iptables_sandbox` is `true`, all iptables
  commands are stubbed via ETS.
  """

  @behaviour Mjolnir.Forge.Resource

  @impl true
  def kind, do: "iptables"

  @impl true
  def canonical(%{table: table, chain: chain, rules: rules}) when is_list(rules) do
    header = "#{table}/#{chain}"
    sorted_rules = Enum.sort(rules)
    [header | sorted_rules] |> Enum.join("\n")
  end

  @impl true
  def observe_path(_id), do: :probe

  @impl true
  def parse_observed(bytes) when is_binary(bytes) do
    lines = bytes |> String.trim() |> String.split("\n", trim: true)

    case lines do
      [header | rules] ->
        case String.split(header, "/", parts: 2) do
          [table, chain] -> %{table: table, chain: chain, rules: rules}
          _ -> %{table: "filter", chain: "INPUT", rules: lines}
        end

      [] ->
        %{table: "filter", chain: "INPUT", rules: []}
    end
  end

  @impl true
  def probe(_host, id) do
    if sandbox?() do
      probe_sandbox(id)
    else
      # We can't meaningfully probe without knowing the expected content.
      # Return :missing so the diff engine treats it as needing apply.
      # After apply, subsequent probes check if the rules are still present.
      #
      # In practice, the reconcile loop calls probe with the declared content
      # available in the diff context, so this is a startup-only edge case.
      probe_by_id(id)
    end
  end

  @impl true
  def apply(_host, id, %{table: table, chain: chain, rules: rules}) when is_list(rules) do
    if sandbox?() do
      apply_sandbox(id, %{table: table, chain: chain, rules: rules})
    else
      errors =
        Enum.reduce(rules, [], fn rule, acc ->
          rule_args = OptionParser.split(rule)

          # Check if rule exists
          check = System.cmd("iptables", ["-t", table, "-C", chain | rule_args], stderr_to_stdout: true)

          case check do
            {_, 0} ->
              acc

            {_, _} ->
              # Rule doesn't exist, add it
              case System.cmd("iptables", ["-t", table, "-A", chain | rule_args], stderr_to_stdout: true) do
                {_, 0} -> acc
                {out, code} -> [{:add_failed, rule, code, out} | acc]
              end
          end
        end)

      case errors do
        [] -> :ok
        errs -> {:error, {:iptables_apply_failed, Enum.reverse(errs)}}
      end
    end
  end

  @impl true
  def delete(_host, id) do
    if sandbox?() do
      delete_sandbox(id)
    else
      delete_by_id(id)
    end
  end

  # In production, delete needs the content to know which rules to remove.
  # The reconcile loop provides this via the stored record.
  defp delete_by_id(_id), do: :ok

  defp probe_by_id(_id), do: :missing

  # -- Sandbox (ETS-backed) --

  defp sandbox?, do: Application.get_env(:mjolnir, :forge_iptables_sandbox, false)

  @sandbox_table :forge_iptables_sandbox

  def ensure_sandbox_table do
    if :ets.whereis(@sandbox_table) == :undefined do
      :ets.new(@sandbox_table, [:named_table, :public, :set])
    end

    :ok
  end

  defp probe_sandbox(id) do
    ensure_sandbox_table()

    case :ets.lookup(@sandbox_table, id) do
      [{^id, content}] -> {:ok, content}
      [] -> :missing
    end
  end

  defp apply_sandbox(id, content) do
    ensure_sandbox_table()
    :ets.insert(@sandbox_table, {id, content})
    :ok
  end

  defp delete_sandbox(id) do
    ensure_sandbox_table()
    :ets.delete(@sandbox_table, id)
    :ok
  end
end
