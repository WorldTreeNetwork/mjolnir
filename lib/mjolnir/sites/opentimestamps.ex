defmodule Mjolnir.Sites.OpenTimestamps do
  @moduledoc """
  Wraps the `ots` (opentimestamps-client) CLI for submission, upgrade, and
  verification of OpenTimestamps receipts.

  Receipts are stored as `.ots` files alongside manifests (see Sites.Store).

  Phase 1 shells out to the Python `opentimestamps-client` binary (`ots`).
  The binary must be on PATH. When it is absent, all functions return
  `{:error, :ots_not_installed}` (or `false` for `available?/0`), so callers
  can degrade gracefully without hard-failing the publish flow.

  See `docs/plans/initiatives/identikey-sites.md` §6.1.1.
  """

  require Logger

  @ots_bin "ots"

  ## Public API

  @doc """
  Submit `envelope_bytes` to the default OpenTimestamps calendar servers.

  Writes the bytes to a temporary file, runs `ots stamp <tmpfile>`, reads back
  the resulting `<tmpfile>.ots` receipt, cleans up, and returns the receipt
  bytes in "pending" state (not yet Bitcoin-anchored).

  Returns `{:ok, receipt_bytes}` or `{:error, reason}`.
  """
  @spec submit(binary()) :: {:ok, binary()} | {:error, term()}
  def submit(envelope_bytes) when is_binary(envelope_bytes) do
    with :ok <- require_ots() do
      tmp = temp_path("ots-submit")
      ots_tmp = tmp <> ".ots"

      try do
        :ok = File.write!(tmp, envelope_bytes)

        case System.cmd(@ots_bin, ["stamp", tmp], stderr_to_stdout: true) do
          {_output, 0} ->
            case File.read(ots_tmp) do
              {:ok, receipt_bytes} ->
                {:ok, receipt_bytes}

              {:error, :enoent} ->
                {:error, {:ots_no_receipt, "stamp succeeded but .ots file not written"}}

              {:error, reason} ->
                {:error, {:ots_read_failed, reason}}
            end

          {output, exit_code} ->
            Logger.warning(
              "Sites.OpenTimestamps: ots stamp failed (exit #{exit_code}): #{output}"
            )

            {:error, {:ots_stamp_failed, exit_code}}
        end
      rescue
        e ->
          Logger.error("Sites.OpenTimestamps: submit raised: #{inspect(e)}")
          {:error, {:ots_exception, e}}
      after
        _ = File.rm(tmp)
        _ = File.rm(ots_tmp)
      end
    end
  end

  @doc """
  Try to upgrade a pending `.ots` receipt to Bitcoin-anchored state.

  Passes the receipt bytes through `ots upgrade` (via a temp file). Returns:

  - `{:ok, :upgraded, new_bytes}` — the calendar returned a block proof; the
    caller should atomically rewrite the stored receipt with `new_bytes`.
  - `{:ok, :still_pending}` — Bitcoin confirmation not yet available.
  - `{:error, reason}` — I/O or CLI error.
  """
  @spec upgrade(binary()) :: {:ok, :upgraded, binary()} | {:ok, :still_pending} | {:error, term()}
  def upgrade(receipt_bytes) when is_binary(receipt_bytes) do
    with :ok <- require_ots() do
      tmp = temp_path("ots-upgrade") <> ".ots"

      try do
        :ok = File.write!(tmp, receipt_bytes)

        case System.cmd(@ots_bin, ["upgrade", tmp], stderr_to_stdout: true) do
          {output, 0} ->
            case File.read(tmp) do
              {:ok, new_bytes} when new_bytes != receipt_bytes ->
                {:ok, :upgraded, new_bytes}

              {:ok, _same} ->
                # File unchanged — calendar hasn't confirmed yet.
                # Also check output for explicit "pending" signal.
                if String.contains?(output, "Pending") or String.contains?(output, "pending") do
                  {:ok, :still_pending}
                else
                  {:ok, :still_pending}
                end

              {:error, reason} ->
                {:error, {:ots_read_failed, reason}}
            end

          {output, exit_code} ->
            if pending_output?(output) do
              {:ok, :still_pending}
            else
              Logger.warning(
                "Sites.OpenTimestamps: ots upgrade failed (exit #{exit_code}): #{output}"
              )

              {:error, {:ots_upgrade_failed, exit_code}}
            end
        end
      rescue
        e ->
          Logger.error("Sites.OpenTimestamps: upgrade raised: #{inspect(e)}")
          {:error, {:ots_exception, e}}
      after
        _ = File.rm(tmp)
      end
    end
  end

  @doc """
  Verify a receipt against the original envelope bytes.

  Returns the Bitcoin-attested `DateTime` if the proof is complete, `:pending`
  if the receipt is still awaiting Bitcoin confirmation, or `{:error, reason}`
  on failure.
  """
  @spec verify(binary(), binary()) :: {:ok, DateTime.t()} | :pending | {:error, term()}
  def verify(envelope_bytes, receipt_bytes)
      when is_binary(envelope_bytes) and is_binary(receipt_bytes) do
    with :ok <- require_ots() do
      tmp_data = temp_path("ots-verify")
      tmp_ots = tmp_data <> ".ots"

      try do
        :ok = File.write!(tmp_data, envelope_bytes)
        :ok = File.write!(tmp_ots, receipt_bytes)

        case System.cmd(@ots_bin, ["verify", tmp_ots], stderr_to_stdout: true) do
          {output, 0} ->
            parse_verify_output(output)

          {output, _exit_code} ->
            if pending_output?(output) do
              :pending
            else
              {:error, {:ots_verify_failed, output}}
            end
        end
      rescue
        e ->
          Logger.error("Sites.OpenTimestamps: verify raised: #{inspect(e)}")
          {:error, {:ots_exception, e}}
      after
        _ = File.rm(tmp_data)
        _ = File.rm(tmp_ots)
      end
    end
  end

  @doc """
  Returns `true` if the `ots` CLI is available on PATH, `false` otherwise.
  """
  @spec available?() :: boolean()
  def available? do
    case System.cmd("which", [@ots_bin], stderr_to_stdout: true) do
      {_path, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  ## Internals

  defp require_ots do
    if available?(), do: :ok, else: {:error, :ots_not_installed}
  end

  defp temp_path(prefix) do
    unique = System.unique_integer([:positive, :monotonic])
    Path.join(System.tmp_dir!(), "#{prefix}-#{unique}")
  end

  # `ots upgrade` exits non-zero and prints "Pending" when the calendar
  # hasn't confirmed yet — treat that as still_pending rather than an error.
  defp pending_output?(output) do
    lower = String.downcase(output)
    String.contains?(lower, "pending") or String.contains?(lower, "not yet")
  end

  # Parse the timestamp from `ots verify` output. The CLI prints something like:
  #   Success! Bitcoin block 123456 attests existence as of 2024-01-15T10:30:00+0000
  defp parse_verify_output(output) do
    # Try to extract an ISO-8601-ish date from the output.
    case Regex.run(~r/(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{4})/, output) do
      [_, ts_str] ->
        # Normalize +0000 → +00:00 for DateTime.from_iso8601
        normalized = Regex.replace(~r/([+-])(\d{2})(\d{2})$/, ts_str, "\\1\\2:\\3")

        case DateTime.from_iso8601(normalized) do
          {:ok, dt, _offset} -> {:ok, dt}
          _ -> {:ok, :verified_unknown_time}
        end

      nil ->
        if String.contains?(output, "Success") or String.contains?(output, "success") do
          {:ok, :verified_unknown_time}
        else
          :pending
        end
    end
  end
end
