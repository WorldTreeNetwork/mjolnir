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

        file "/etc/motd" do
          source "Welcome\\n"
          mode 0o644
        end
      end

  The `systemd_unit/2` and `file/2` macros parse their block as a sequence of
  field calls and accumulate the result into the module's `@forge_resources`
  attribute. After compilation the module exposes `__forge_host__/0` and
  `__forge_resources__/0`, used by `Mjolnir.Forge.Declarations` to assemble
  the per-host resource map.
  """

  @doc false
  defmacro __using__(opts) do
    host = Keyword.fetch!(opts, :host)

    quote do
      import Mjolnir.Forge.Declaration, only: [systemd_unit: 2, file: 2]
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

  @doc """
  Declare a plain file resource. The macro argument is the file path, which
  also serves as the resource ID (paths are unique identifiers).

  Block fields:
    * `source <binary>` — file contents (required)
    * `mode <integer>` — octal permission bits, e.g. `0o644` (default `0o644`)
    * `owner <binary>` — UNIX owner name, e.g. `"root"` (default `nil` = leave as-is)
    * `group <binary>` — UNIX group name (default `nil` = leave as-is)

  Example:

      file "/etc/motd" do
        source "Welcome\\n"
        mode 0o644
      end
  """
  defmacro file(path, do: block) do
    stmts =
      case block do
        {:__block__, _, list} -> list
        single -> [single]
      end

    init =
      quote do
        content = %{path: unquote(path), source: nil, mode: 0o644, owner: nil, group: nil}
      end

    assigns =
      Enum.map(stmts, fn
        {field, _meta, [value]} when field in [:source, :mode, :owner, :group] ->
          quote do
            content = Map.put(content, unquote(field), unquote(value))
          end

        other ->
          raise CompileError,
            description:
              "unsupported call in file/2 block: #{Macro.to_string(other)}. " <>
                "Allowed: source/mode/owner/group."
      end)

    push =
      quote do
        @forge_resources {Mjolnir.Forge.Resource.File, unquote(path), content}
      end

    {:__block__, [], [init] ++ assigns ++ [push]}
  end
end
