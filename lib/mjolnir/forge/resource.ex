defmodule Mjolnir.Forge.Resource do
  @moduledoc """
  Behaviour for a kind of host resource (systemd unit, sysctl, file, ufw rule, ...).

  Each kind implements:

    * `kind/0` — string identifier used in storage and APIs
    * `canonical/1` — deterministic byte encoding of content, for hashing
    * `observe_path/1` — `{:file, path}` for file-backed kinds; `:probe` for
      kinds that must shell out
    * `parse_observed/1` — for file-backed kinds, parse raw bytes from disk
      into the same shape `canonical/1` accepts
    * `probe/2` — for probe-backed kinds, return the observed content
    * `apply/3` — write the resource to disk + perform any side effects
      (daemon-reload, ufw reload, etc.)
    * `delete/2` — remove the resource and its side effects
    * `to_declaration/2` — render a content map back into a DSL block
      (`<macro> "<id>" do ... end`), the inverse of the `Declaration` macros.
      Used by adopt + overwrite-decl-from-observed to author `.exs` files.

  Apply is idempotent destroy-then-create: callers may invoke `apply/3` in any
  state — the implementation is responsible for getting the host to the
  desired state.
  """

  @type host :: String.t()
  @type id :: String.t()
  @type content :: term()

  @callback kind() :: String.t()
  @callback canonical(content()) :: binary()
  @callback observe_path(id()) :: {:file, Path.t()} | :probe
  @callback parse_observed(binary()) :: content()
  @callback probe(host(), id()) :: {:ok, content()} | :missing | {:error, term()}
  @callback apply(host(), id(), content()) :: :ok | {:error, term()}
  @callback delete(host(), id()) :: :ok | {:error, term()}
  @callback to_declaration(id(), content()) :: iodata()

  @doc """
  Optional: enumerate the ids of this kind currently present on the host, so
  host-wide discovery can surface undeclared (`:unmanaged`) resources. Only
  kinds with a sensible, bounded universe implement this — systemd units, apt
  packages, users. File/sysctl/iptables have no enumerable namespace and are
  adopted by name instead.
  """
  @callback enumerate(host()) :: [id()]

  @optional_callbacks [probe: 2, parse_observed: 1, enumerate: 1]

  @doc "Resource kinds that support host-wide enumeration for discovery."
  @spec enumerable_kinds() :: [module()]
  def enumerable_kinds do
    [
      Mjolnir.Forge.Resource.SystemdUnit,
      Mjolnir.Forge.Resource.AptPackage,
      Mjolnir.Forge.Resource.User
    ]
  end

  @doc """
  Enumerate ids of `mod` on `host` via `transport`. Returns `[]` for kinds that
  don't implement `enumerate/1` and for `:ssh` (enumeration over SSH is a later
  ticket, same as the rest of the SSH transport).
  """
  @spec enumerate(module(), :local | :ssh, host()) :: [id()]
  def enumerate(_mod, :ssh, _host), do: []

  def enumerate(mod, :local, host) do
    # Gate on the static enumerable list, not `function_exported?/3` — the
    # latter depends on the module's *loaded* state, which `Code.compile_*` in
    # the test suite can perturb (a direct call auto-loads; the check does not).
    #
    # Degrade to `[]` if a kind's enumeration raises — its backing command may
    # be absent on this host (no `apt` / `getent`, or a non-Linux dev box). One
    # kind failing must not abort discovery of the others.
    if mod in enumerable_kinds() do
      try do
        mod.enumerate(host)
      rescue
        e ->
          require Logger
          Logger.debug("Forge.enumerate #{inspect(mod)} failed: #{inspect(e)}")
          []
      end
    else
      []
    end
  end

  @doc """
  Render a declaration DSL block:

      <macro> "<id>" do
        <field> <value>
        ...
      end

  `fields` is a list of `{field_atom, rendered_value}` where the value is
  already a string of valid Elixir source (typically `inspect/1` output).
  Callers omit fields that should fall back to DSL defaults (e.g. a `nil`
  owner). Kinds use this in `to_declaration/2` so block formatting lives in
  one place.
  """
  @spec render_block(String.t(), id(), [{atom(), iodata()}]) :: iodata()
  def render_block(macro, id, fields) do
    lines = Enum.map(fields, fn {f, v} -> ["  ", Atom.to_string(f), " ", v, "\n"] end)
    [macro, " ", inspect(id), " do\n", lines, "end\n"]
  end

  @doc """
  Observe the current state of a resource on a host via the given transport.
  Returns `{:present, content}`, `:missing`, or `{:error, reason}`.

  Transport is `:local | :ssh` — local reads files directly; SSH is a v1
  ticket and currently stubs out.
  """
  @spec observe(module(), :local | :ssh, host(), id()) ::
          {:present, content()} | :missing | {:error, term()}
  def observe(mod, transport, host, id) do
    case mod.observe_path(id) do
      {:file, path} ->
        case read_file(transport, host, path) do
          {:ok, bytes} -> {:present, mod.parse_observed(bytes)}
          :missing -> :missing
          {:error, _} = err -> err
        end

      :probe ->
        case mod.probe(host, id) do
          {:ok, content} -> {:present, content}
          :missing -> :missing
          {:error, _} = err -> err
        end
    end
  end

  defp read_file(:local, _host, path), do: read_local(path)
  defp read_file(:ssh, _host, _path), do: {:error, :ssh_transport_not_implemented_yet}

  defp read_local(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> :missing
      {:error, _} = err -> err
    end
  end
end
