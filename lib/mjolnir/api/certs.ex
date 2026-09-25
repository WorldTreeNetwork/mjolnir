defmodule Mjolnir.API.Certs do
  @moduledoc """
  On-demand ACME HTTP-01 issuance for CNAME'd custom domains (mjolnir-r7b3.3).

  Backs `POST /api/certs/issue` and `GET /api/certs`. The Mac client only POSTs
  an fqdn — issuance runs on the host. Challenge files are planted in
  `/var/lib/mjolnir-gateway/http-01` by a `systemd-run` one-shot as the
  `mjolnir` user (the BEAM's `ProtectSystem=strict` cannot write that dir, and
  we must not add `ReadWritePaths` — that would restart `mjolnir.service` and
  kill VMs). The **running** gateway already serves the challenges.

  After Let's Encrypt returns a cert, `Mjolnir.Gateway.Certs.ensure/2` installs
  a `[[cert]]` entry. PEMs never leave the host.

  `renew_due/1` is the daily pass (`systemd/mjolnir-cert-renew.timer`). It
  re-issues at most one `[[cert]]` whose `not_after` is inside 30 days, the
  soonest first. The gateway's own 12-hour loop only renews the worldtree
  DNS-01 certificate and does not look at these files.

  Wildcards (`*.`) are refused — HTTP-01 cannot prove them. v1 has no
  `--wildcard` flag.

  ## The ops seam (never hits LE in tests)

  `issue_cmd`, `ensure`, and `list_certs` are injectable. Tests pass a fake
  `issue_cmd` that returns canned PEMs and a fake `ensure` that records the
  install without touching `/etc` or talking to Let's Encrypt.
  """

  require Logger

  alias Mjolnir.Gateway.Certs, as: GatewayCerts

  @default_http01_dir "/var/lib/mjolnir-gateway/http-01"
  @default_issued_dir "/var/lib/mjolnir-gateway/issued"
  @gateway_bin "/usr/local/bin/mjolnir-gateway"
  @default_email "duke@worldtree.io"
  # Same window as the gateway's primary ACME loop (`renew_before_secs`).
  @renew_before_seconds 30 * 24 * 60 * 60

  @typedoc "Injectable effect seam; defaults capture the real host commands."
  @type ops :: %{
          issue_cmd: (String.t() -> {:ok, map()} | {:error, term()}),
          ensure: (String.t(), String.t(), String.t() -> {:ok, atom()} | {:error, term()}),
          list_certs: (-> {:ok, [map()]} | {:error, term()})
        }

  @doc """
  Issue a public cert for `fqdn` via HTTP-01 and install it as `[[cert]]`.

  Returns:
    - `{:ok, %{fqdn, status, not_after}}` — PEMs are never included
    - `{:error, :wildcard_not_supported}` — `*.` names are refused
    - `{:error, {:issue_failed, code, output}}` — the one-shot failed
    - `{:error, {:ensure_failed, reason}}` — issued but `[[cert]]` install failed
  """
  @spec issue(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue(fqdn, opts \\ []) when is_binary(fqdn) do
    fqdn = normalize_fqdn(fqdn)
    ops = merged_ops(opts)

    cond do
      fqdn == "" ->
        {:error, :fqdn_required}

      wildcard?(fqdn) ->
        {:error, :wildcard_not_supported}

      true ->
        do_issue(fqdn, ops)
    end
  end

  @doc """
  Re-issue at most one installed `[[cert]]` that expires within 30 days.

  Already-expired certificates count. An unreadable `not_after` counts, so a
  certificate we cannot date does not sit there forever. Wildcards are skipped.
  When several are due, the soonest (or undated) one is the only one issued
  this call — the timer runs daily, so the rest drain one per day instead of
  hitting Let's Encrypt all at once.

  Returns `{:ok, :none}` or the same map as `issue/2`.
  """
  @spec renew_due(keyword()) :: {:ok, :none | map()} | {:error, term()}
  def renew_due(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    within = Keyword.get(opts, :within_seconds, @renew_before_seconds)
    ops = merged_ops(opts)

    case ops.list_certs.() do
      {:ok, certs} ->
        case next_due(certs, now, within) do
          nil ->
            Logger.info("cert renew: none due")
            {:ok, :none}

          host ->
            Logger.info("cert renew: issuing #{host}")
            issue(host, opts)
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "Like `renew_due/1`, but raises on `{:error, _}` so a systemd oneshot fails."
  @spec renew_due!(keyword()) :: :none | map()
  def renew_due!(opts \\ []) do
    case renew_due(opts) do
      {:ok, result} -> result
      {:error, reason} -> raise "cert renewal failed: #{inspect(reason)}"
    end
  end

  @doc """
  List installed `[[cert]]` entries. Paths and PEMs are stripped — the public
  shape is `%{host, not_after, issuer, sans}` per cert.
  """
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ []) do
    ops = merged_ops(opts)

    case ops.list_certs.() do
      {:ok, certs} -> {:ok, Enum.map(certs, &public_cert/1)}
      {:error, _} = err -> err
    end
  end

  # --- internals -------------------------------------------------------------

  defp do_issue(fqdn, ops) do
    case ops.issue_cmd.(fqdn) do
      {:ok, issued} ->
        case ops.ensure.(fqdn, issued.cert, issued.key) do
          {:ok, status} ->
            {:ok,
             %{
               fqdn: fqdn,
               status: status,
               not_after: Map.get(issued, :not_after)
             }}

          {:error, reason} ->
            {:error, {:ensure_failed, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp public_cert(c) when is_map(c) do
    %{
      host: Map.get(c, :host) || Map.get(c, "host"),
      not_after: Map.get(c, :not_after) || Map.get(c, "not_after"),
      issuer: Map.get(c, :issuer) || Map.get(c, "issuer"),
      sans: Map.get(c, :sans) || Map.get(c, "sans")
    }
  end

  defp merged_ops(opts), do: Map.merge(default_ops(), Map.new(Keyword.get(opts, :ops, [])))

  defp default_ops do
    %{
      issue_cmd: &default_issue_cmd/1,
      ensure: &default_ensure/3,
      list_certs: &default_list_certs/0
    }
  end

  defp default_ensure(fqdn, cert, key) do
    GatewayCerts.ensure(fqdn, cert: cert, key: key)
  end

  defp default_list_certs, do: GatewayCerts.list()

  # One-shot as the mjolnir user so ProtectSystem=strict on mjolnir.service
  # does not block the http-01 webroot. The running gateway serves it.
  defp default_issue_cmd(fqdn) do
    slug = GatewayCerts.slugify(fqdn)
    out = Path.join(issued_dir(), slug)
    email = acme_email()
    http01_dir = http01_dir()

    args = [
      "--wait",
      "--collect",
      "--uid=mjolnir",
      "--gid=mjolnir",
      @gateway_bin,
      "cert",
      "issue",
      "--domain",
      fqdn,
      "--email",
      email,
      "--out",
      out,
      "--http01-dir",
      http01_dir
    ]

    case System.cmd("systemd-run", args, stderr_to_stdout: true) do
      {_output, 0} ->
        read_issued(out)

      {output, code} ->
        Logger.error("cert issue failed for #{fqdn} (exit #{code}): #{output}")
        {:error, {:issue_failed, code, output}}
    end
  rescue
    e ->
      {:error, {:issue_failed, :spawn, Exception.message(e)}}
  end

  defp read_issued(out) do
    cert_path = Path.join(out, "fullchain.pem")
    key_path = Path.join(out, "privkey.pem")

    with {:ok, cert} <- File.read(cert_path),
         {:ok, key} <- File.read(key_path) do
      {:ok, %{cert: cert, key: key, not_after: read_not_after(out)}}
    else
      {:error, reason} -> {:error, {:issue_failed, :missing_pem, reason}}
    end
  end

  defp read_not_after(out) do
    case File.read(Path.join(out, "metadata.json")) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"not_after_unix" => secs}} when is_integer(secs) ->
            secs |> DateTime.from_unix!() |> DateTime.to_iso8601()

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp next_due(certs, now, within) do
    certs
    |> Enum.map(&cert_host/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&wildcard?/1)
    |> Enum.filter(&due?(&1, cert_not_after(certs, &1), now, within))
    |> Enum.sort_by(&expiry_unix(cert_not_after(certs, &1)))
    |> List.first()
  end

  defp cert_host(c), do: Map.get(c, :host) || Map.get(c, "host")

  defp cert_not_after(certs, host) do
    certs
    |> Enum.find(fn c -> cert_host(c) == host end)
    |> then(fn c -> Map.get(c, :not_after) || Map.get(c, "not_after") end)
  end

  defp due?(_host, not_after, now, within) do
    case expiry(not_after) do
      {:ok, dt} -> DateTime.diff(dt, now, :second) <= within
      :error -> true
    end
  end

  defp expiry_unix(not_after) do
    case expiry(not_after) do
      {:ok, dt} -> DateTime.to_unix(dt)
      :error -> 0
    end
  end

  defp expiry(%DateTime{} = dt), do: {:ok, dt}

  defp expiry(secs) when is_integer(secs) do
    case DateTime.from_unix(secs) do
      {:ok, dt} -> {:ok, dt}
      _ -> :error
    end
  end

  defp expiry(stamp) when is_binary(stamp) do
    stamp = stamp |> String.trim() |> String.replace_prefix("notAfter=", "")

    case DateTime.from_iso8601(stamp) do
      {:ok, dt, _} ->
        {:ok, dt}

      _ ->
        openssl_time(stamp)
    end
  end

  defp expiry(_), do: :error

  # `openssl x509 -enddate`: "Sep 22 22:42:17 2026 GMT" (day may be space-padded).
  defp openssl_time(stamp) do
    case Regex.run(
           ~r/\A([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})\s+GMT\z/,
           stamp
         ) do
      [_, mon, day, hour, min, sec, year] ->
        with {:ok, month} <- month_number(mon),
             {:ok, naive} <-
               NaiveDateTime.new(
                 String.to_integer(year),
                 month,
                 String.to_integer(day),
                 String.to_integer(hour),
                 String.to_integer(min),
                 String.to_integer(sec)
               ) do
          DateTime.from_naive(naive, "Etc/UTC")
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp month_number(mon) do
    months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

    case Enum.find_index(months, &(&1 == mon)) do
      nil -> :error
      idx -> {:ok, idx + 1}
    end
  end

  defp normalize_fqdn(fqdn) do
    fqdn |> String.trim() |> String.trim_trailing(".") |> String.downcase()
  end

  defp wildcard?(fqdn), do: String.starts_with?(fqdn, "*.")

  defp http01_dir do
    Application.get_env(:mjolnir, :http01_dir, @default_http01_dir)
  end

  defp issued_dir do
    Application.get_env(:mjolnir, :cert_issue_out_dir, @default_issued_dir)
  end

  defp acme_email do
    Application.get_env(:mjolnir, :acme_email, @default_email)
  end
end
