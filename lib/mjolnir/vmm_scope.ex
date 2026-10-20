defmodule Mjolnir.VmmScope do
  @moduledoc "Guest scope launch, explicit stop, and an independent witness process."

  @namespaces [
    {"mjolnir-vms.slice", "mjolnir-"},
    {"mjt-vms.slice", "mjt-"},
    {"mjd-vms.slice", "mjd-"}
  ]

  def namespace do
    slice = Application.get_env(:mjolnir, :vmm_slice, "mjolnir-vms.slice")
    prefix = Application.get_env(:mjolnir, :vmm_scope_prefix, "mjolnir-")
    validate_namespace!(slice, prefix)
    {slice, prefix}
  end

  def validate_namespace!(slice, prefix, peers \\ @namespaces) do
    unless Regex.match?(~r/^[a-zA-Z0-9]+-vms\.slice$/, slice) and
             Regex.match?(~r/^[a-zA-Z0-9]+-$/, prefix) do
      raise ArgumentError, "expected a sibling <instance>-vms.slice and <instance>- scope prefix"
    end

    Enum.each(peers, fn {other_slice, other_prefix} ->
      unless {slice, prefix} == {other_slice, other_prefix} do
        if slice == other_slice or String.starts_with?(prefix, other_prefix) or
             String.starts_with?(other_prefix, prefix) do
          raise ArgumentError, "guest namespace collides with #{other_slice}/#{other_prefix}"
        end
      end
    end)

    :ok
  end

  def scope_name(id) do
    {_, prefix} = namespace()

    unless Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/, id),
      do: raise(ArgumentError, "invalid guest id")

    prefix <> id <> ".scope"
  end

  # Unit names alone are never membership evidence.
  def member?(properties, slice), do: properties["Slice"] == slice

  def launch_spec(id, hypervisor_argv, daemons) do
    {slice, _} = namespace()

    {"systemd-run",
     [
       "--scope",
       "--quiet",
       "--unit=#{scope_name(id)}",
       "--slice=#{slice}",
       "--property=CollectMode=inactive-or-failed",
       "--",
       "/bin/bash",
       "-c",
       wrapper(hypervisor_argv, daemons)
     ]}
  end

  def wrapper(hypervisor_argv, daemons) do
    starts =
      Enum.map_join(daemons, "\n", fn daemon ->
        # Each daemon's output goes to a file, never to the orchestrator's pipe.
        "# virtiofs tag: #{inspect(daemon.tag)}\n" <>
          command(daemon.argv) <>
          " >> " <>
          quote_arg(daemon.socket <> ".log") <>
          " 2>&1 < /dev/null &\npids+=(\"$!\")"
      end)

    readiness =
      Enum.map_join(daemons, "\n", fn daemon ->
        "for ((i=0; i<500; i++)); do\n" <>
          "  [[ -S #{quote_arg(daemon.socket)} ]] && break\n" <>
          "  sleep 0.01\ndone\n[[ -S #{quote_arg(daemon.socket)} ]] || exit 1"
      end)

    """
    pids=()
    cleanup() {
      trap '' TERM INT HUP
      if ((${#pids[@]})); then
        kill -KILL "${pids[@]}" 2>/dev/null || true
        wait "${pids[@]}" 2>/dev/null || true
      fi
    }
    trap cleanup EXIT
    trap 'exit 143' TERM INT
    trap '' HUP
    #{starts}
    #{readiness}
    #{command(hypervisor_argv)} < /dev/null >> /dev/null 2>&1 &
    vmm=$!
    wait "$vmm"
    status=$?
    exit "$status"
    """
  end

  defp command(argv), do: Enum.map_join(argv, " ", &quote_arg/1)
  defp quote_arg(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  def start(id, hypervisor_argv, daemons) do
    Enum.each(daemons, fn daemon ->
      File.mkdir_p!(Path.dirname(daemon.socket))
      File.rm(daemon.socket)
    end)

    {bin, argv} = launch_spec(id, hypervisor_argv, daemons)
    executable = System.find_executable(bin) || raise "systemd-run is required"

    {:ok,
     Port.open({:spawn_executable, executable}, [
       :binary,
       :exit_status,
       :stderr_to_stdout,
       args: argv
     ])}
  rescue
    e -> {:error, {:scope_start_failed, e}}
  end

  def stop(id, runner \\ &System.cmd/3) do
    {slice, _} = namespace()
    unit = scope_name(id)

    case runner.("systemctl", ["show", unit, "--property=Slice", "--property=LoadState"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        properties = parse_properties(output)

        cond do
          properties["LoadState"] == "not-found" ->
            :ok

          member?(properties, slice) ->
            case runner.("systemctl", ["stop", unit], stderr_to_stdout: true) do
              {_, 0} -> :ok
              {out, code} -> {:error, {:scope_stop_failed, code, out}}
            end

          true ->
            {:error, :foreign_or_unclassified_scope}
        end

      {out, code} ->
        {:error, {:scope_lookup_failed, code, out}}
    end
  end

  def parse_properties(output) do
    output
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    end)
  end

  def detach?(reason), do: reason != :normal and not match?({:hypervisor_exit, _}, reason)

  def detach(port) when is_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  def detach(_), do: :ok

  @doc "Manual witness. The systemd unit runs priv/vmm_watch.py and does not start this BEAM."
  def watch do
    {slice, _} = namespace()

    path =
      Application.get_env(:mjolnir, :vmm_watch_record, "/var/lib/mjolnir/vmm-watch-#{slice}.json")

    {_, status} =
      System.cmd("/usr/bin/python3", ["-u", "-c", watcher_source(), slice, path],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0, do: raise("scope witness exited: #{status}")
  end

  # sd-bus is supplied by systemd. No Python dbus package is needed. The
  # witness is this script, started by mjolnir-vmm-watch.service. It is not
  # a second BEAM. Subscribe on the same connection before the snapshot.
  @doc false
  def watcher_source do
    Path.join(:code.priv_dir(:mjolnir), "vmm_watch.py")
    |> File.read!()
  end
end
