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

  @optional_callbacks [probe: 2, parse_observed: 1]

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
