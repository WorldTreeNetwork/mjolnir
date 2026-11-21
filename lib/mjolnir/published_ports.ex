defmodule Mjolnir.PublishedPorts do
  @moduledoc """
  Published UDP ports: one host port goes to one guest port, in the kernel.

  A datagram that arrives on the public interface at UDP `host_port` is
  DNATed to `guest_ip:guest_port`. Replies go back through conntrack. There
  is no userspace proxy. The rules do not depend on the guest kind; they
  need only the TAP and the guest address.

  ## Who may publish

  The same shape as `extra_mounts` and `:allowed_mount_prefixes`: the host
  operator opts in by config, and any caller that may spawn (`vms:spawn`)
  may then publish inside what the operator allowed.

    * `:published_port_range` is `{first, last}` or `nil`. `nil` is the
      default and it disables the feature. `MJOLNIR_PUBLISHED_PORT_RANGE`
      (`20000-20099`) sets it.
    * `:published_port_reserved` is refused even inside the range.
    * A port some host socket has bound for UDP is refused. DNAT runs
      before local delivery, so a published port would take that socket's
      new inbound flows.
    * `:published_ports_max_per_vm` (default 4).
    * A host port has one holder. A VM holds its ports while it has a
      StateStore record of any intent, a dormant entry, or a live process.

  Keep the range below the kernel's ephemeral range (32768 and up) so the
  host's own outgoing UDP sockets do not land in it.

  ## Public side

  `:published_port_interface` (`MJOLNIR_PUBLISHED_PORT_INTERFACE`) names the
  ingress interface. Unset, it is the interface of the IPv4 default route,
  the same one the MASQUERADE rule uses. The address is that interface's
  IPv4 address at the time the rules are written; the VM re-checks it and
  rewrites the rules when it changes.

  ## Rules

  Each rule carries the comment `<tap_prefix>publish:<vm_id>`. A VM removes
  its rules when it stops. `Mjolnir.Cleanup` removes the rules of ids that
  have no `:running` record. A second BEAM with another `:tap_prefix`
  never sees them.
  """

  require Logger

  alias Mjolnir.{LanFiles, Network, StateStore}

  @default_reserved [53, 67, 68, 123, 443, 500, 4000, 4500, 5353, 5432, 6379, 7222, 7422, 51820]
  @default_max 4

  @type port_map :: %{protocol: String.t(), host_port: 1..65535, guest_port: 1..65535}
  @type rule :: {String.t(), String.t(), [String.t()]}

  # ── Parsing ────────────────────────────────────────────────────────────

  @doc """
  Strict parse of a spawn request's `published_ports`.

  Each entry is `%{"host_port" => h, "guest_port" => g}`. `guest_port`
  defaults to `host_port`. `protocol` defaults to `"udp"`, the only one.
  For a unikernel `guest_port` may be `"quic"`: the Reflect QUIC port is
  derived from the VM id, which the caller does not have yet.
  """
  @spec parse(term()) :: {:ok, [map()]} | {:error, term()}
  def parse(nil), do: {:ok, []}

  def parse(entries) when is_list(entries) do
    parsed =
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
        case parse_entry(entry) do
          {:ok, port} -> {:cont, {:ok, [port | acc]}}
          :error -> {:halt, {:error, {:invalid_published_port, entry}}}
        end
      end)

    with {:ok, ports} <- parsed do
      ports = Enum.reverse(ports)
      hosts = Enum.map(ports, & &1.host_port)

      cond do
        length(ports) > max_per_vm() ->
          {:error, {:too_many_published_ports, max_per_vm()}}

        hosts != Enum.uniq(hosts) ->
          {:error, {:duplicate_host_port, hd(hosts -- Enum.uniq(hosts))}}

        true ->
          {:ok, ports}
      end
    end
  end

  def parse(_), do: {:error, :invalid_published_ports}

  defp parse_entry(entry) when is_map(entry) do
    host = field(entry, :host_port)
    guest = field(entry, :guest_port) || host
    protocol = field(entry, :protocol) || "udp"

    with true <- protocol in ["udp", :udp],
         {:ok, host} <- port_number(host),
         {:ok, guest} <- guest_port(guest) do
      {:ok, %{protocol: "udp", host_port: host, guest_port: guest}}
    else
      _ -> :error
    end
  end

  defp parse_entry(_), do: :error

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp port_number(port) when is_integer(port) and port in 1..65535, do: {:ok, port}
  defp port_number(_), do: :error

  defp guest_port(port) when port in ["quic", :quic], do: {:ok, :quic}
  defp guest_port(port), do: port_number(port)

  @doc """
  Replace a symbolic guest port by its number once the VM id exists.

  `:quic` is the unikernel's QUIC port. On a Linux guest it is an error.
  """
  @spec resolve([map()], :linux | :unikernel, String.t()) ::
          {:ok, [port_map()]} | {:error, term()}
  def resolve(ports, kind, vm_id) when is_list(ports) do
    Enum.reduce_while(ports, {:ok, []}, fn
      %{guest_port: :quic} = port, {:ok, acc} when kind == :unikernel ->
        {_udp, quic} = Mjolnir.Unikernel.ports(vm_id)
        {:cont, {:ok, [%{port | guest_port: quic} | acc]}}

      %{guest_port: :quic}, _acc ->
        {:halt, {:error, :quic_guest_port_requires_unikernel}}

      port, {:ok, acc} ->
        {:cont, {:ok, [port | acc]}}
    end)
    |> case do
      {:ok, ports} -> {:ok, Enum.reverse(ports)}
      error -> error
    end
  end

  @doc "Lenient read of a stored value. A record written before this field has none."
  @spec decode(term()) :: [port_map()]
  def decode(entries) when is_list(entries) do
    Enum.flat_map(entries, fn entry ->
      case parse_entry(entry) do
        {:ok, %{guest_port: guest} = port} when is_integer(guest) -> [port]
        _ -> []
      end
    end)
    |> Enum.uniq_by(& &1.host_port)
  end

  def decode(_), do: []

  @doc "JSON form, for StateStore and the API."
  @spec encode([map()]) :: [map()]
  def encode(ports) when is_list(ports) do
    for %{host_port: host, guest_port: guest} <- ports do
      %{"protocol" => "udp", "host_port" => host, "guest_port" => guest}
    end
  end

  def encode(_), do: []

  # ── Admission ──────────────────────────────────────────────────────────

  @doc """
  Decide a spawn request before any VM process starts.

  Options are for tests: `:range`, `:reserved`, `:bound` (UDP ports the host
  has bound), `:holders` (`%{host_port => vm_id}`), `:public` (a 0-arity
  function that returns `{:ok, {interface, address}}`).
  """
  @spec check([map()], keyword()) :: :ok | {:error, term()}
  def check(ports, opts \\ [])
  def check([], _opts), do: :ok

  def check(ports, opts) when is_list(ports) do
    range = Keyword.get_lazy(opts, :range, &range/0)

    with :ok <- enabled(range),
         :ok <- each(ports, &permitted(&1, range)),
         reserved = Keyword.get_lazy(opts, :reserved, &reserved/0),
         :ok <- each(ports, &not_in(&1, reserved, :host_port_reserved)),
         holders = Keyword.get_lazy(opts, :holders, &holders/0),
         :ok <- each(ports, &not_held(&1, holders)),
         bound = Keyword.get_lazy(opts, :bound, &bound_udp_ports/0),
         :ok <- each(ports, &not_in(&1, bound, :host_port_bound_by_host)),
         {:ok, _} <- Keyword.get(opts, :public, &public/0).() do
      :ok
    end
  end

  defp enabled({first, last}) when is_integer(first) and is_integer(last) and first <= last,
    do: :ok

  defp enabled(_), do: {:error, :published_ports_disabled}

  defp permitted(%{host_port: port}, {first, last}) do
    if port >= first and port <= last,
      do: :ok,
      else: {:error, {:host_port_not_permitted, port, first, last}}
  end

  defp not_in(%{host_port: port}, set, reason) do
    if port in set, do: {:error, {reason, port}}, else: :ok
  end

  defp not_held(%{host_port: port}, holders) do
    case Map.get(holders, port) do
      nil -> :ok
      vm_id -> {:error, {:host_port_published, port, vm_id}}
    end
  end

  defp each(ports, fun) do
    Enum.find_value(ports, :ok, fn port ->
      case fun.(port) do
        :ok -> nil
        error -> error
      end
    end)
  end

  @doc "Configured `{first, last}`, or `nil` when publishing is disabled."
  def range, do: Application.get_env(:mjolnir, :published_port_range)

  @doc "Parse `\"20000-20099\"` (or one port) into a range. Anything else is `nil`."
  @spec parse_range(term()) :: {pos_integer(), pos_integer()} | nil
  def parse_range(value) when is_binary(value) do
    numbers =
      value
      |> String.split("-", trim: true)
      |> Enum.map(&Integer.parse(String.trim(&1)))

    case numbers do
      [{port, ""}] when port in 1..65535 ->
        {port, port}

      [{first, ""}, {last, ""}] when first in 1..65535 and last >= first and last <= 65535 ->
        {first, last}

      _ ->
        nil
    end
  end

  def parse_range(_), do: nil

  @doc """
  Host ports never published: the configured list, the API port and the
  syslog UDP port. The sidecar numbers are TCP, and are kept out anyway so
  that a port number means one thing on this host.
  """
  @spec reserved() :: MapSet.t()
  def reserved do
    configured = Application.get_env(:mjolnir, :published_port_reserved, @default_reserved)
    syslog = Application.get_env(:mjolnir, :syslog, [])
    syslog_port = if Keyword.keyword?(syslog), do: syslog[:udp_port]

    [Application.get_env(:mjolnir, :api_port, 4000), syslog_port | configured]
    |> Enum.filter(&is_integer/1)
    |> MapSet.new()
  end

  def max_per_vm, do: Application.get_env(:mjolnir, :published_ports_max_per_vm, @default_max)

  @doc "UDP ports with a bound socket on this host, IPv4 and IPv6."
  @spec bound_udp_ports() :: MapSet.t()
  def bound_udp_ports do
    ["/proc/net/udp", "/proc/net/udp6"]
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, text} -> parse_proc_udp(text)
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  @doc false
  def parse_proc_udp(text) when is_binary(text) do
    for line <- String.split(text, "\n", trim: true),
        [_slot, local | _] <- [String.split(line)],
        [_addr, hex] <- [String.split(local, ":")],
        {port, ""} <- [Integer.parse(hex, 16)],
        port > 0,
        do: port
  end

  @doc """
  `%{host_port => vm_id}` for every VM that holds a port: live processes,
  StateStore records of any intent, and dormant entries.
  """
  @spec holders() :: %{optional(pos_integer()) => String.t()}
  def holders do
    live =
      Registry.select(Mjolnir.VMRegistry, [
        {{{:published_port, :"$1"}, :_, :"$2"}, [], [{{:"$1", :"$2"}}]}
      ])

    stored =
      for record <- safe(fn -> StateStore.list() end),
          %{host_port: port} <- decode(Map.get(record.spawn_config || %{}, "published_ports")),
          do: {port, record.uuid}

    dormant =
      for entry <- safe(fn -> Mjolnir.DormantRegistry.list() end),
          config = Map.get(entry, :original_config) || %{},
          stored = Map.get(config, :published_ports) || Map.get(config, "published_ports"),
          %{host_port: port} <- decode(stored),
          do: {port, Map.get(entry, :vm_id)}

    Map.new(dormant ++ stored ++ live)
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Claim the host ports for the calling VM process. Atomic per port, and
  released when the process exits. This closes the race two concurrent
  spawns leave open after `check/2`.
  """
  @spec claim(String.t(), [port_map()]) :: :ok | {:error, term()}
  def claim(vm_id, ports) do
    Enum.reduce_while(ports, :ok, fn %{host_port: port}, :ok ->
      case Registry.register(Mjolnir.VMRegistry, {:published_port, port}, vm_id) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, {:already_registered, pid}} when pid == self() ->
          {:cont, :ok}

        {:error, {:already_registered, pid}} ->
          holder =
            case Registry.lookup(Mjolnir.VMRegistry, {:published_port, port}) do
              [{^pid, id}] -> id
              _ -> nil
            end

          Enum.each(
            ports,
            &Registry.unregister(Mjolnir.VMRegistry, {:published_port, &1.host_port})
          )

          {:halt, {:error, {:host_port_published, port, holder}}}
      end
    end)
  end

  # ── Rules ──────────────────────────────────────────────────────────────

  @doc "Comment on every rule of `vm_id`. Scoped by `:tap_prefix`, like TAP names."
  def tag(vm_id), do: tag_prefix() <> vm_id

  def tag_prefix, do: Network.tap_prefix() <> "publish:"

  @doc "Ingress interface and its IPv4 address."
  @spec public() :: {:ok, {String.t(), String.t()}} | {:error, term()}
  def public do
    interface =
      case Application.get_env(:mjolnir, :published_port_interface) do
        name when is_binary(name) and name != "" -> {:ok, name}
        _ -> Network.default_route_iface()
      end

    with {:ok, name} <- interface,
         {:ok, address} <- LanFiles.interface_ipv4(name) do
      {:ok, {name, address}}
    else
      _ -> {:error, :published_port_interface_unavailable}
    end
  end

  @doc "Rules this VM should have now. Empty without ports, a TAP, or a public address."
  @spec desired(String.t(), [port_map()], map() | nil, (-> term())) :: [rule()]
  def desired(vm_id, ports, net_config, public \\ &public/0)
  def desired(_vm_id, [], _net, _public), do: []

  def desired(vm_id, ports, %{tap_name: tap, guest_ip: guest}, public) when is_list(ports) do
    case public.() do
      {:ok, {interface, address}} ->
        Network.published_port_rules(tag(vm_id), interface, address, tap, guest, ports)

      _ ->
        []
    end
  end

  def desired(_vm_id, _ports, _net, _public), do: []

  @doc """
  Write the rules for a VM whose TAP exists. Returns the rules now owned.

  With ports to publish and no public address this is an error, not an
  empty success.
  """
  @spec install(String.t(), [port_map()], map(), keyword()) ::
          {:ok, [rule()]} | {:error, term()}
  def install(vm_id, ports, net_config, opts \\ [])
  def install(_vm_id, [], _net, _opts), do: {:ok, []}

  def install(vm_id, ports, net_config, opts) do
    run = Keyword.get(opts, :run, &iptables/1)

    case desired(vm_id, ports, net_config, Keyword.get(opts, :public, &public/0)) do
      [] ->
        {:error, :published_port_interface_unavailable}

      rules ->
        case LanFiles.reconcile([], rules, run) do
          {:ok, owned} ->
            {:ok, owned}

          {:error, reason, partial} ->
            _ = LanFiles.reconcile(partial, [], run)
            {:error, {:published_port_rules_failed, reason}}
        end
    end
  end

  @doc "Move from the owned rules to the desired ones. Old rules go first."
  @spec sync([rule()], [rule()], (list() -> term())) ::
          {:ok, [rule()]} | {:error, term(), [rule()]}
  def sync(owned, desired, run \\ &iptables/1), do: LanFiles.reconcile(owned, desired, run)

  @doc "Remove every rule tagged for `vm_id`, whatever address it was written with."
  @spec remove(String.t(), (list() -> term())) :: :ok
  def remove(vm_id, run \\ &iptables/1) do
    for {table, ^vm_id, args} <- tagged_rules(run), do: run.(["-t", table | args])
    :ok
  end

  @doc "Remove the rules of a stored VM that will not run again without an operator."
  def release(%{uuid: uuid, spawn_config: config}) do
    if decode(Map.get(config || %{}, "published_ports")) != [], do: remove(uuid)
    :ok
  rescue
    _ -> :ok
  end

  def release(_), do: :ok

  @doc """
  Startup sweep. Removes the rules of every id for which `keep?` is false.
  By default an id is kept while it has a `:running` record; if the store
  cannot answer, the rule stays.
  """
  @spec sweep(keyword()) :: [String.t()]
  def sweep(opts \\ []) do
    keep? = Keyword.get(opts, :keep, &running_record?/1)
    run = Keyword.get(opts, :run, &iptables/1)

    stale =
      for {table, vm_id, args} <- tagged_rules(run), not keep?.(vm_id) do
        run.(["-t", table | args])
        vm_id
      end

    stale = Enum.uniq(stale)
    if stale != [], do: Logger.info("Removed stale published-port rules for: #{inspect(stale)}")
    stale
  end

  defp running_record?(vm_id) do
    case StateStore.get(vm_id) do
      {:ok, %{intent: :running}} -> true
      {:ok, _} -> false
      :not_found -> false
    end
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  # DNAT first, so nothing new is translated while the accepts go.
  defp tagged_rules(run) do
    for {table, chain} <- [{"nat", "PREROUTING"}, {"filter", "FORWARD"}],
        {out, 0} <- [run.(["-t", table, "-S", chain])],
        line <- String.split(out, "\n", trim: true),
        {vm_id, args} <- [parse_tagged(line, tag_prefix())],
        do: {table, vm_id, args}
  rescue
    _ -> []
  end

  @doc """
  Turn one `iptables -S` line that carries our tag into `{vm_id, delete_args}`.

  No token of ours has a space, so the line splits on whitespace; iptables
  may or may not quote the comment.
  """
  @spec parse_tagged(String.t(), String.t()) :: {String.t(), [String.t()]} | nil
  def parse_tagged(line, prefix) do
    tokens = line |> String.split() |> Enum.map(&String.trim(&1, "\""))

    with ["-A", chain | spec] <- tokens,
         index when is_integer(index) <- Enum.find_index(spec, &(&1 == "--comment")),
         comment when is_binary(comment) <- Enum.at(spec, index + 1),
         true <- String.starts_with?(comment, prefix),
         vm_id when vm_id != "" <- String.replace_prefix(comment, prefix, "") do
      {vm_id, ["-D", chain | spec]}
    else
      _ -> nil
    end
  end

  defp iptables(args),
    do: System.cmd("sudo", ["-n", "iptables", "-w", "5" | args], stderr_to_stdout: true)
end
