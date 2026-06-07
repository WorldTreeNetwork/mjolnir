defmodule Mjolnir.Syslog.Message do
  @moduledoc """
  Struct representing a parsed syslog message (RFC 3164 / RFC 5424).

  ## Facilities (0-23)

  - 0  `:kern`    — kernel messages
  - 1  `:user`    — user-level messages
  - 2  `:mail`    — mail system
  - 3  `:daemon`  — system daemons
  - 4  `:auth`    — security/auth messages
  - 5  `:syslog`  — syslogd internal messages
  - 6  `:lpr`     — line printer subsystem
  - 7  `:news`    — network news subsystem
  - 8  `:uucp`    — UUCP subsystem
  - 9  `:cron`    — clock daemon
  - 10 `:authpriv`— security/auth messages (private)
  - 11 `:ftp`     — FTP daemon
  - 16 `:local0` through 23 `:local7` — local use 0-7

  ## Severities (0-7)

  - 0 `:emergency` — system is unusable
  - 1 `:alert`     — action must be taken immediately
  - 2 `:critical`  — critical conditions
  - 3 `:error`     — error conditions
  - 4 `:warning`   — warning conditions
  - 5 `:notice`    — normal but significant condition
  - 6 `:info`      — informational messages
  - 7 `:debug`     — debug-level messages
  """

  @enforce_keys [:raw]
  defstruct [
    :facility,
    :severity,
    :timestamp,
    :hostname,
    :tag,
    :pid,
    :message,
    :raw
  ]

  @type facility ::
          :kern
          | :user
          | :mail
          | :daemon
          | :auth
          | :syslog
          | :lpr
          | :news
          | :uucp
          | :cron
          | :authpriv
          | :ftp
          | :local0
          | :local1
          | :local2
          | :local3
          | :local4
          | :local5
          | :local6
          | :local7
          | :unknown

  @type severity ::
          :emergency
          | :alert
          | :critical
          | :error
          | :warning
          | :notice
          | :info
          | :debug
          | :unknown

  @type t :: %__MODULE__{
          facility: facility() | nil,
          severity: severity() | nil,
          timestamp: NaiveDateTime.t() | nil,
          hostname: String.t() | nil,
          tag: String.t() | nil,
          pid: non_neg_integer() | nil,
          message: String.t() | nil,
          raw: String.t()
        }
end
