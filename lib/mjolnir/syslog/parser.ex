defmodule Mjolnir.Syslog.Parser do
  @moduledoc """
  Parses RFC 3164 (BSD syslog) messages.

  RFC 3164 format produced by busybox syslogd:

      <PRI>TIMESTAMP HOSTNAME TAG[PID]: MESSAGE
      <PRI>TIMESTAMP HOSTNAME TAG: MESSAGE

  Examples:

      <134>Jun  6 12:34:56 vm-abc ci[1234]: + npm install
      <13>Jan  1 00:00:00 myhost kernel: some message
      <165>Aug 24 05:34:00 mymachine myproc[10]: %% It's time to make the do-nuts.

  Priority value encodes facility and severity:

      facility = pri div 8
      severity = pri rem 8
  """

  alias Mjolnir.Syslog.Message

  # Months for RFC 3164 timestamp parsing
  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  @facility_names %{
    0 => :kern,
    1 => :user,
    2 => :mail,
    3 => :daemon,
    4 => :auth,
    5 => :syslog,
    6 => :lpr,
    7 => :news,
    8 => :uucp,
    9 => :cron,
    10 => :authpriv,
    11 => :ftp,
    16 => :local0,
    17 => :local1,
    18 => :local2,
    19 => :local3,
    20 => :local4,
    21 => :local5,
    22 => :local6,
    23 => :local7
  }

  @severity_names %{
    0 => :emergency,
    1 => :alert,
    2 => :critical,
    3 => :error,
    4 => :warning,
    5 => :notice,
    6 => :info,
    7 => :debug
  }

  @doc """
  Parse a syslog line into a `Mjolnir.Syslog.Message` struct.

  Returns `{:ok, message}` on success.
  Returns `{:error, :malformed}` with a best-effort struct on failure — the
  struct will always have `:raw` populated.

  Handles malformed messages gracefully: unknown fields become `nil`, facility
  and severity become `:unknown`.
  """
  @spec parse(String.t()) :: {:ok, Message.t()} | {:error, :malformed, Message.t()}
  def parse(line) when is_binary(line) do
    raw = String.trim_trailing(line, "\n")

    case parse_priority(raw) do
      {:ok, facility, severity, rest} ->
        case parse_header(rest) do
          {:ok, timestamp, hostname, rest2} ->
            {tag, pid, message} = parse_msg_part(rest2)

            msg = %Message{
              facility: facility,
              severity: severity,
              timestamp: timestamp,
              hostname: hostname,
              tag: tag,
              pid: pid,
              message: message,
              raw: raw
            }

            {:ok, msg}

          :error ->
            {:error, :malformed, %Message{facility: facility, severity: severity, raw: raw}}
        end

      :error ->
        {:error, :malformed, %Message{raw: raw}}
    end
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  # Parse <PRI> prefix — returns {:ok, facility_atom, severity_atom, rest} or :error
  defp parse_priority(<<"<", rest::binary>>) do
    case String.split(rest, ">", parts: 2) do
      [pri_str, after_pri] ->
        case Integer.parse(pri_str) do
          {pri, ""} when pri >= 0 and pri <= 191 ->
            facility_num = div(pri, 8)
            severity_num = rem(pri, 8)
            facility = Map.get(@facility_names, facility_num, :unknown)
            severity = Map.get(@severity_names, severity_num, :unknown)
            {:ok, facility, severity, after_pri}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp parse_priority(_), do: :error

  # Parse "MMM DD HH:MM:SS HOSTNAME " — RFC 3164 timestamp + hostname
  # Returns {:ok, timestamp_or_nil, hostname, rest} or :error
  defp parse_header(str) do
    # RFC 3164: "Mmm dd hh:mm:ss hostname " (dd may have leading space for single digits)
    # Pattern: 3-letter month, space, 1-2 digit day (space-padded), space, HH:MM:SS, space, hostname, space
    case Regex.run(
           ~r/\A([A-Z][a-z]{2}) {1,2}(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\S+) (.*)\z/s,
           str
         ) do
      [_, month_str, day_str, hour_str, min_str, sec_str, hostname, rest] ->
        timestamp = build_timestamp(month_str, day_str, hour_str, min_str, sec_str)
        {:ok, timestamp, hostname, rest}

      _ ->
        :error
    end
  end

  defp build_timestamp(month_str, day_str, hour_str, min_str, sec_str) do
    with {:ok, month} <- Map.fetch(@months, month_str),
         {day, ""} <- Integer.parse(day_str),
         {hour, ""} <- Integer.parse(hour_str),
         {minute, ""} <- Integer.parse(min_str),
         {second, ""} <- Integer.parse(sec_str) do
      # RFC 3164 has no year; use current year as best approximation
      year = Date.utc_today().year

      case NaiveDateTime.new(year, month, day, hour, minute, second) do
        {:ok, dt} -> dt
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  # Parse "TAG[PID]: MESSAGE" or "TAG: MESSAGE" or just the message string
  defp parse_msg_part(str) do
    # Try "TAG[PID]: MESSAGE"
    case Regex.run(~r/\A([A-Za-z0-9_\-\.\/]+)\[(\d+)\]: (.*)\z/s, str) do
      [_, tag, pid_str, message] ->
        {pid, _} = Integer.parse(pid_str)
        {tag, pid, message}

      _ ->
        # Try "TAG: MESSAGE"
        case Regex.run(~r/\A([A-Za-z0-9_\-\.\/]+): (.*)\z/s, str) do
          [_, tag, message] ->
            {tag, nil, message}

          _ ->
            # No tag — treat whole string as message
            {nil, nil, str}
        end
    end
  end
end
