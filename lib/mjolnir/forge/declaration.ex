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
      import Mjolnir.Forge.Declaration,
        only: [
          systemd_unit: 2,
          file: 2,
          sysctl: 2,
          apt_package: 2,
          user: 2,
          ufw_nat: 2,
          iptables: 2
        ]

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

  @doc """
  Declare a sysctl kernel parameter.

  Block fields:
    * `value <binary>` — the desired parameter value (required)

  Example:

      sysctl "net.ipv4.ip_forward" do
        value "1"
      end
  """
  defmacro sysctl(key, do: block) do
    stmts =
      case block do
        {:__block__, _, list} -> list
        single -> [single]
      end

    init =
      quote do
        content = %{value: nil}
      end

    assigns =
      Enum.map(stmts, fn
        {:value, _meta, [val]} ->
          quote do
            content = Map.put(content, :value, unquote(val))
          end

        other ->
          raise CompileError,
            description:
              "unsupported call in sysctl/2 block: #{Macro.to_string(other)}. " <>
                "Allowed: value."
      end)

    push =
      quote do
        @forge_resources {Mjolnir.Forge.Resource.Sysctl, unquote(key), content}
      end

    {:__block__, [], [init] ++ assigns ++ [push]}
  end

  @doc """
  Declare an apt package.

  Block fields:
    * `state :installed | :removed | :held` — desired package state (default `:installed`)
    * `version <binary>` — pin to a specific version (default `nil` = latest)

  Example:

      apt_package "nginx" do
        state :installed
      end

      apt_package "cloud-hypervisor" do
        state :held
        version "50.0"
      end
  """
  defmacro apt_package(name, do: block) do
    stmts =
      case block do
        {:__block__, _, list} -> list
        single -> [single]
      end

    init =
      quote do
        content = %{state: :installed, version: nil}
      end

    assigns =
      Enum.map(stmts, fn
        {field, _meta, [value]} when field in [:state, :version] ->
          quote do
            content = Map.put(content, unquote(field), unquote(value))
          end

        other ->
          raise CompileError,
            description:
              "unsupported call in apt_package/2 block: #{Macro.to_string(other)}. " <>
                "Allowed: state/version."
      end)

    push =
      quote do
        @forge_resources {Mjolnir.Forge.Resource.AptPackage, unquote(name), content}
      end

    {:__block__, [], [init] ++ assigns ++ [push]}
  end

  @doc """
  Declare a Linux user account.

  Block fields:
    * `state :present | :absent` — whether the user should exist (default `:present`)
    * `uid <integer>` — explicit UID (default `nil` = system-assigned)
    * `shell <binary>` — login shell (default `nil` = system default)
    * `home <binary>` — home directory path (default `nil` = system default)
    * `groups [<binary>, ...]` — supplementary groups (default `nil`)
    * `system true | false` — create as system user (default `false`)

  Example:

      user "mjolnir_pg" do
        state :present
        system true
        shell "/usr/sbin/nologin"
        home "/nonexistent"
      end
  """
  defmacro user(name, do: block) do
    stmts =
      case block do
        {:__block__, _, list} -> list
        single -> [single]
      end

    init =
      quote do
        content = %{state: :present, uid: nil, shell: nil, home: nil, groups: nil, system: false}
      end

    assigns =
      Enum.map(stmts, fn
        {field, _meta, [value]} when field in [:state, :uid, :shell, :home, :groups, :system] ->
          quote do
            content = Map.put(content, unquote(field), unquote(value))
          end

        other ->
          raise CompileError,
            description:
              "unsupported call in user/2 block: #{Macro.to_string(other)}. " <>
                "Allowed: state/uid/shell/home/groups/system."
      end)

    push =
      quote do
        @forge_resources {Mjolnir.Forge.Resource.User, unquote(name), content}
      end

    {:__block__, [], [init] ++ assigns ++ [push]}
  end

  @doc """
  Declare a NAT rule block for `/etc/ufw/before.rules`.

  The block is managed as a marker-delimited section inside before.rules,
  so multiple `ufw_nat` resources can coexist without clobbering each other.

  Block fields:
    * `rules <binary>` — the iptables *nat rules (required)

  Example:

      ufw_nat "mjolnir-vm-nat" do
        rules \"\"\"
        *nat
        :POSTROUTING ACCEPT [0:0]
        -A POSTROUTING -s 10.192.0.0/10 -o enp1s0 -j MASQUERADE
        COMMIT
        \"\"\"
      end
  """
  defmacro ufw_nat(id, do: block) do
    stmts =
      case block do
        {:__block__, _, list} -> list
        single -> [single]
      end

    init =
      quote do
        content = %{rules: nil}
      end

    assigns =
      Enum.map(stmts, fn
        {:rules, _meta, [value]} ->
          quote do
            content = Map.put(content, :rules, unquote(value))
          end

        other ->
          raise CompileError,
            description:
              "unsupported call in ufw_nat/2 block: #{Macro.to_string(other)}. " <>
                "Allowed: rules."
      end)

    push =
      quote do
        @forge_resources {Mjolnir.Forge.Resource.UfwNat, unquote(id), content}
      end

    {:__block__, [], [init] ++ assigns ++ [push]}
  end

  @doc """
  Declare iptables rules for a specific table and chain.

  Block fields:
    * `table <binary>` — iptables table: "nat", "filter", "mangle", "raw" (default "filter")
    * `chain <binary>` — chain name: "INPUT", "FORWARD", "POSTROUTING", etc. (required)
    * `rules [<binary>, ...]` — list of rule specs without the `-A CHAIN` prefix (required)

  Example:

      iptables "mjolnir-forward" do
        table "filter"
        chain "FORWARD"
        rules [
          "-i mj-+ -o mj-+ -j ACCEPT",
          "-i mj-+ -o enp1s0 -j ACCEPT",
          "-i enp1s0 -o mj-+ -m state --state RELATED,ESTABLISHED -j ACCEPT"
        ]
      end
  """
  defmacro iptables(name, do: block) do
    stmts =
      case block do
        {:__block__, _, list} -> list
        single -> [single]
      end

    init =
      quote do
        content = %{table: "filter", chain: nil, rules: []}
      end

    assigns =
      Enum.map(stmts, fn
        {field, _meta, [value]} when field in [:table, :chain, :rules] ->
          quote do
            content = Map.put(content, unquote(field), unquote(value))
          end

        other ->
          raise CompileError,
            description:
              "unsupported call in iptables/2 block: #{Macro.to_string(other)}. " <>
                "Allowed: table/chain/rules."
      end)

    push =
      quote do
        @forge_resources {Mjolnir.Forge.Resource.Iptables, unquote(name), content}
      end

    {:__block__, [], [init] ++ assigns ++ [push]}
  end
end
