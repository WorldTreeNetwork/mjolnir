defmodule Mjolnir.Deploy.Diagnostics do
  @moduledoc """
  Preserve evidence from a build VM before `Mjolnir.Deploy.Builder` discards it.

  ## Why

  A failed build step used to leave nothing behind. `run_build/8` tears the
  ephemeral VM down in an `after` block, and the serial console — the only place
  the guest **kernel** speaks — dies with it. So a bundler killed by the guest
  OOM killer surfaced to the operator as:

      {:step_failed, "... && bun run build",
       {:vsock_unavailable, {:normal, {GenServer, :call, ...}}}}

  which says only "the agent stopped answering". Memory exhaustion, a disk-full,
  a segfault and a genuinely bad command all produce that same shape. Debugging
  meant guessing, and each guess cost a full deploy cycle.

  The serial log already exists on disk while the VM lives
  (`<socket_dir>/<vm_id>_serial.log`, written by Cloud Hypervisor in `File`
  mode). This module copies it somewhere durable and, more usefully, extracts
  the handful of lines that actually explain a death.

  ## What ends up on disk

      <deploy_state_dir>/failures/<iso8601>-<vm-prefix>/
        serial.log     — tail of the guest serial console (bounded)
        context.json   — vm_id, failing command, reason, highlights

  Bounded on purpose: a boot log is mostly systemd progress spam, and an
  unbounded copy per failed build is a disk leak in the same directory an
  operator goes to when something is already wrong.
  """

  require Logger

  # Serial logs are dominated by systemd's ANSI progress redraw. The tail is
  # where a death shows up, and 256KB is far more than any kernel splat needs.
  @tail_bytes 256 * 1024

  # Lines worth showing an operator, in rough order of how conclusive they are.
  # Deliberately narrow: a highlights list that includes everything is the same
  # as no highlights at all.
  @signals [
    ~r/Out of memory/i,
    ~r/oom[-_]kill/i,
    ~r/Killed process/i,
    ~r/Kernel panic/i,
    ~r/BUG: /,
    ~r/segfault/i,
    ~r/No space left on device/i,
    ~r/I\/O error/i,
    ~r/EXT4-fs error|BTRFS error|virtio_fs.*error/i,
    ~r/systemd\[1\]: .*(Failed|failed with result)/
  ]

  @doc """
  Capture what the VM can still tell us, then return where it went.

  `context` is recorded verbatim into `context.json` — pass the failing command
  and the error reason. Never raises: diagnostics failing must not mask the
  build failure that triggered them.
  """
  @spec capture(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def capture(vm_id, context \\ []) when is_binary(vm_id) do
    dir = Path.join(failures_root(), "#{stamp()}-#{String.slice(vm_id, 0, 8)}")
    File.mkdir_p!(dir)

    serial = read_serial_tail(vm_id)
    highlights = highlights(serial)

    if serial != "", do: File.write(Path.join(dir, "serial.log"), serial)

    File.write(
      Path.join(dir, "context.json"),
      Jason.encode!(
        %{
          vm_id: vm_id,
          captured_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          serial_bytes: byte_size(serial),
          highlights: highlights,
          context: Map.new(context, fn {k, v} -> {k, inspect(v)} end)
        },
        pretty: true
      )
    )

    {:ok, %{dir: dir, highlights: highlights}}
  rescue
    e ->
      Logger.warning("Deploy.Diagnostics: capture failed for #{vm_id}: #{Exception.message(e)}")
      {:error, e}
  end

  @doc """
  Extract the lines from a serial log that plausibly explain a death.

  Strips ANSI (systemd's progress redraw makes raw greps useless) and keeps only
  lines matching a known failure signal. Returns `[]` when the guest died
  silently — itself a useful signal, since it rules out the kernel having
  complained.
  """
  @spec highlights(String.t()) :: [String.t()]
  def highlights(serial) when is_binary(serial) do
    serial
    |> String.split(~r/\r?\n/)
    |> Enum.map(&strip_ansi/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn line ->
      line != "" and Enum.any?(@signals, &Regex.match?(&1, line))
    end)
    |> Enum.uniq()
    |> Enum.take(-40)
  end

  @doc """
  A one-line operator-facing summary of a capture, safe to log or return.
  """
  @spec summarize(map()) :: String.t()
  def summarize(%{dir: dir, highlights: []}),
    do: "no kernel-level cause found in the serial console; full log at #{dir}"

  def summarize(%{dir: dir, highlights: highlights}) do
    "serial console says: #{Enum.join(Enum.take(highlights, 3), " | ")} (full log at #{dir})"
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # ANSI CSI sequences plus the lone \r systemd uses to redraw its progress line.
  defp strip_ansi(line) do
    line
    |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
    |> String.replace(~r/\e[@-Z\\-_]/, "")
  end

  defp read_serial_tail(vm_id) do
    path = serial_log_path(vm_id)

    with {:ok, %{size: size}} <- File.stat(path),
         {:ok, io} <- :file.open(path, [:raw, :read, :binary]) do
      offset = max(size - @tail_bytes, 0)

      result =
        case :file.pread(io, offset, min(size, @tail_bytes)) do
          {:ok, data} -> data
          _ -> ""
        end

      :file.close(io)
      result
    else
      _ -> ""
    end
  end

  @doc "Path Cloud Hypervisor writes the guest serial console to."
  @spec serial_log_path(String.t()) :: String.t()
  def serial_log_path(vm_id) do
    Path.join(socket_dir(), "#{vm_id}_serial.log")
  end

  defp socket_dir, do: Application.get_env(:mjolnir, :socket_dir, "/tmp/mjolnir")

  # A SIBLING of the registry dir, not a child of it.
  #
  # :deploy_state_dir points at `<deploy>/registry` (see Mjolnir.Deploy.Registry),
  # which Registry scans on boot. Nesting captures underneath it would put
  # operator debris inside a directory whose contents are meant to be exactly
  # one JSON file per deployed app — today load_from_disk/2 only globs `*.json`
  # at the top level so it would tolerate this, but that is a coincidence, not a
  # contract. This yields /var/lib/mjolnir/deploy/failures, alongside the
  # existing registry/ and src/.
  defp failures_root do
    Application.get_env(:mjolnir, :deploy_failures_dir) ||
      Application.get_env(:mjolnir, :deploy_state_dir, "/var/lib/mjolnir/deploy/registry")
      |> Path.dirname()
      |> Path.join("failures")
  end

  defp stamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[^0-9TZ]/, "")
  end
end
