defmodule Mjolnir.Forge.Declaration do
  @moduledoc """
  DSL for `forge/declarations/<host>.exs` files.

  Example:

      defmodule Forge.Declarations.MjolnirHost do
        use Mjolnir.Forge.Declaration, host: "self"

        systemd_unit "mjolnir.service" do
          source File.read!("systemd/mjolnir.service")
          enabled true
          state   :running
        end
      end

  The `systemd_unit`/2 macro parses its block as a sequence of field calls
  (`source <value>`, `enabled <value>`, `state <value>`) and accumulates the
  result into the module's `@forge_resources` attribute. After compilation
  the module exposes `__forge_host__/0` and `__forge_resources__/0`, used by
  `Mjolnir.Forge.Declarations` to assemble the per-host resource map.
  """

  @doc false
  defmacro __using__(opts) do
    host = Keyword.fetch!(opts, :host)

    quote do
      import Mjolnir.Forge.Declaration, only: [systemd_unit: 2]
      Module.register_attribute(__MODULE__, :forge_resources, accumulate: true)
      @forge_host unquote(host)
      @before_compile Mjolnir.Forge.Declaration
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      def __forge_host__, do: @forge_host
      def __forge_resources__, do: Enum.reverse(@forge_resources)
    end
  end

  @doc """
  Declare a systemd unit. The block accepts `source <bin>`, `enabled <bool>`,
  `state <:running | :stopped>` — defaults are `enabled: true, state: :running`.
  """
  defmacro systemd_unit(id, do: block) do
    stmts =
      case block do
        {:__block__, _, list} -> list
        single -> [single]
      end

    init =
      quote do
        content = %{source: nil, enabled: true, state: :running}
      end

    assigns =
      Enum.map(stmts, fn
        {field, _meta, [value]} when field in [:source, :enabled, :state] ->
          quote do
            content = Map.put(content, unquote(field), unquote(value))
          end

        other ->
          raise CompileError,
            description:
              "unsupported call in systemd_unit/2 block: #{Macro.to_string(other)}. " <>
                "Allowed: source/enabled/state."
      end)

    push =
      quote do
        @forge_resources {Mjolnir.Forge.Resource.SystemdUnit, unquote(id), content}
      end

    {:__block__, [], [init] ++ assigns ++ [push]}
  end
end
