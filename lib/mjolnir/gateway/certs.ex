defmodule Mjolnir.Gateway.Certs do
  @moduledoc """
  Per-domain TLS certificate provisioning for the Rust `mjolnir-gateway`.

  The gateway (`native/mjolnir_gateway`, config `/etc/mjolnir/gateway.toml`)
  serves TLS one of two ways:

    * `[acme]` — Let's Encrypt via DNS-01. The Cloudflare token is scoped to the
      **worldtree** zones only, so ACME can *only* auto-issue for hostnames under
      those zones. Arbitrary customer apex domains cannot be issued this way.
    * `[[cert]]` — a hand-installed "bring-your-own" / Origin-CA cert. The gateway
      serves the PEM at `cert`/`key` when the TLS SNI matches `host`. This is how
      `zine.identikey.io` and `startupcentral.build` are served today.

  This module owns the Elixir side of the **Origin-CA / BYO** path (the primary
  path for custom apex domains) and a guarded ACME path:

    * writes the cert + key PEM under `/etc/mjolnir/certs/<slug>/`
      (`fullchain.pem` / `privkey.pem`), owned by the gateway user (999:988),
      key mode `0600`;
    * ensures a `[[cert]] host=… cert=… key=…` entry and a `[[domain]]
      suffix=<apex>` entry exist in the base `gateway.toml`;
    * requests a gateway reload (`systemctl reload mjolnir-gateway`, which
      SIGHUPs the gateway — no restart).

  `[[cert]]`/`[[domain]]` blocks must live in the **base** `gateway.toml`, not in
  a `gateway.d/*.toml` drop-in: the gateway rejects drop-ins that declare
  anything beyond `[[route]]`/`[[alias]]` (see `FileConfig::declares_non_route_alias_content`).
  That is why this module edits `gateway.toml` in place rather than dropping a
  file next to `Mjolnir.Gateway.Routes`' `apps.toml`.

  ## Effects seam (macOS-testable)

  Every filesystem / gateway.toml / reload / ownership / openssl effect is
  injectable via `opts` (see `effects/1`), defaulting to the real system. Tests
  pass fakes and assert the choreography (paths, modes, owner, emitted TOML,
  reload, validation, idempotency) without ever touching `/etc` or reloading
  anything.

  ## Integration seam

  The custom-domain endpoint (a separate lane) calls:

      Mjolnir.Gateway.Certs.ensure(fqdn,
        mode: :origin_ca,
        cert: cert_pem,   # fullchain PEM
        key: key_pem      # private-key PEM
      )

  and receives `{:ok, :installed | :unchanged}` or `{:error, reason}`.
  """

  require Logger

  @default_gateway_toml "/etc/mjolnir/gateway.toml"
  @default_certs_dir "/etc/mjolnir/certs"

  # Gateway user (from the deploy). Key is 0600, cert 0644, dir 0755.
  @uid 999
  @gid 988
  @key_mode 0o600
  @cert_mode 0o644
  @dir_mode 0o755

  # Zones the gateway's Cloudflare ACME token can issue for. Anything outside
  # these is unsupported-for-now on the :acme path (explicit error, not silent).
  @default_acme_zones ["worldtree.network", "worldtree.io"]

  @cert_file "fullchain.pem"
  @key_file "privkey.pem"

  @typedoc "Result of an `ensure/2` origin-ca install."
  @type ensure_result ::
          {:ok, :installed | :unchanged | :acme_requested} | {:error, term()}

  # ==========================================================================
  # Public API
  # ==========================================================================

  @doc """
  Ensure a serving TLS cert exists for `fqdn`.

  ## Modes

    * `mode: :origin_ca` (default) — bring-your-own / Cloudflare Origin CA.
      Requires `cert:` and `key:` PEM strings. Validates the pair (public keys
      match) and that the cert's SANs cover `fqdn`, writes the PEM under
      `/etc/mjolnir/certs/<slug>/`, ensures the `[[cert]]` + `[[domain]]` TOML,
      and reloads the gateway. Idempotent: a re-`ensure` with the same PEM +
      existing TOML entry is a no-op returning `{:ok, :unchanged}`.

    * `mode: :acme` — only viable when `fqdn` is under an ACME-issuable zone
      (`:acme_zones`, default the worldtree zones). Adds `fqdn` to
      `[acme].domains` + a `[[domain]]` and reloads. Non-worldtree zones return
      `{:error, {:acme_unsupported_zone, fqdn}}`.

  Returns `{:ok, :installed | :unchanged | :acme_requested}` or `{:error, reason}`.

  ## Options

    * `:mode` — `:origin_ca` (default) | `:acme`
    * `:cert`, `:key` — PEM strings (origin_ca)
    * `:apex` — override the derived apex used for the `[[domain]]` block
    * plus any effect/config override accepted by `effects/1`.
  """
  @spec ensure(String.t(), keyword()) :: ensure_result()
  def ensure(fqdn, opts \\ []) do
    fqdn = normalize_fqdn(fqdn)
    eff = effects(opts)

    case Keyword.get(opts, :mode, :origin_ca) do
      mode when mode in [:origin_ca, :byo] -> ensure_origin_ca(fqdn, opts, eff)
      :acme -> ensure_acme(fqdn, opts, eff)
      other -> {:error, {:unsupported_mode, other}}
    end
  end

  @doc """
  Enumerate the configured `[[cert]]` entries.

  Parses the `[[cert]]` blocks in `gateway.toml` and, for each, reads the cert
  PEM and derives `not_after`/`issuer`/`sans` via the `:cert_info` seam
  (`openssl` by default). Read-only. Returns `{:ok, [map]}` where each map has
  `:host`, `:cert_path`, `:key_path` and (when readable) `:not_after`,
  `:issuer`, `:sans`.
  """
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ []) do
    eff = effects(opts)

    with {:ok, content} <- read_toml(eff) do
      certs =
        content
        |> toml_list_certs()
        |> Enum.map(fn c -> Map.merge(c, cert_details(eff, c.cert_path)) end)

      {:ok, certs}
    end
  end

  @doc """
  Whether a serving `[[cert]]` entry exists for `fqdn` in the gateway config.

  Authoritative for "is TLS wired up for this host" — checks the `[[cert]]`
  block the gateway actually serves, not just a file on disk.
  """
  @spec present?(String.t(), keyword()) :: boolean()
  def present?(fqdn, opts \\ []) do
    fqdn = normalize_fqdn(fqdn)
    eff = effects(opts)

    case read_toml(eff) do
      {:ok, content} -> toml_has_cert?(content, fqdn)
      _ -> false
    end
  end

  @doc """
  Remove the `[[cert]]` (and optionally `[[domain]]`) for `fqdn` and reload.

  Options:

    * `:remove_domain` (default `false`) — also drop the `[[domain]]` for the
      apex. Off by default because an apex `[[domain]]` may be shared by other
      subdomains/routes.
    * `:gc` (default `false`) — also remove the on-disk cert dir.

  Returns `{:ok, :removed}` when a cert entry existed, `{:ok, :absent}` when
  none did, or `{:error, reason}`.
  """
  @spec remove(String.t(), keyword()) :: {:ok, :removed | :absent} | {:error, term()}
  def remove(fqdn, opts \\ []) do
    fqdn = normalize_fqdn(fqdn)
    eff = effects(opts)

    with {:ok, content} <- read_toml(eff) do
      if toml_has_cert?(content, fqdn) do
        content
        |> toml_remove_cert(fqdn)
        |> maybe_remove_domain(fqdn, opts)
        |> write_and_reload(eff, fn ->
          if Keyword.get(opts, :gc, false) do
            eff.rm_rf.(Path.join(eff.certs_dir, slugify(fqdn)))
          end

          :removed
        end)
      else
        {:ok, :absent}
      end
    end
  end

  # ==========================================================================
  # Pure helpers (public — directly unit-testable)
  # ==========================================================================

  @doc """
  Turn an fqdn into a filesystem-safe cert-dir name.

  Keeps dots and hyphens (so ordinary apex domains map to themselves), maps a
  leading `*.` wildcard to `wildcard.`, and replaces any other unsafe char with
  `-`.

      iex> Mjolnir.Gateway.Certs.slugify("StartupCentral.Build")
      "startupcentral.build"
      iex> Mjolnir.Gateway.Certs.slugify("*.example.com")
      "wildcard.example.com"
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(fqdn) do
    fqdn
    |> String.downcase()
    |> String.replace_prefix("*.", "wildcard.")
    |> String.replace(~r/[^a-z0-9.\-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  @doc """
  Derive the apex (registrable domain) used for the `[[domain]]` block.

  Uses `opts[:apex]` when given, otherwise the last two dot-labels of `fqdn`.

      iex> Mjolnir.Gateway.Certs.apex_of("www.startupcentral.build")
      "startupcentral.build"

  Note: naive last-two-labels does not handle multi-part public suffixes like
  `co.uk`; pass `:apex` explicitly for those.
  """
  @spec apex_of(String.t(), keyword()) :: String.t()
  def apex_of(fqdn, opts \\ []) do
    case Keyword.get(opts, :apex) do
      apex when is_binary(apex) and apex != "" ->
        normalize_fqdn(apex)

      _ ->
        fqdn
        |> normalize_fqdn()
        |> String.split(".")
        |> Enum.take(-2)
        |> Enum.join(".")
    end
  end

  @doc "Render a `[[cert]]` block (no trailing newline)."
  @spec render_cert_block(String.t(), String.t(), String.t()) :: String.t()
  def render_cert_block(host, cert_path, key_path) do
    """
    [[cert]]
    host = #{quote_str(host)}
    cert = #{quote_str(cert_path)}
    key = #{quote_str(key_path)}\
    """
  end

  @doc "Render a `[[domain]]` block (no trailing newline)."
  @spec render_domain_block(String.t()) :: String.t()
  def render_domain_block(suffix) do
    """
    [[domain]]
    suffix = #{quote_str(suffix)}\
    """
  end

  # ==========================================================================
  # origin_ca / BYO
  # ==========================================================================

  defp ensure_origin_ca(fqdn, opts, eff) do
    slug = slugify(fqdn)
    dir = Path.join(eff.certs_dir, slug)
    cert_path = Path.join(dir, @cert_file)
    key_path = Path.join(dir, @key_file)

    with {:ok, cert} <- fetch_pem(opts, :cert),
         {:ok, key} <- fetch_pem(opts, :key),
         :ok <- eff.validate_pair.(cert, key),
         :ok <- eff.cert_covers.(cert, fqdn),
         {:ok, content} <- read_toml(eff) do
      apex = apex_of(fqdn, opts)

      files_present? =
        read_matches?(eff, cert_path, cert) and read_matches?(eff, key_path, key)

      if files_present? and toml_has_cert?(content, fqdn) do
        {:ok, :unchanged}
      else
        with :ok <- write_cert_files(eff, dir, cert_path, key_path, cert, key) do
          content
          |> ensure_cert_block(fqdn, cert_path, key_path)
          |> ensure_domain_block(apex)
          |> write_and_reload(eff, fn -> :installed end)
        end
      end
    end
  end

  defp write_cert_files(eff, dir, cert_path, key_path, cert, key) do
    {uid, gid} = eff.owner

    with :ok <- eff.mkdir_p.(dir),
         :ok <- eff.chmod.(dir, @dir_mode),
         :ok <- eff.chown.(dir, uid, gid),
         :ok <- eff.write_file.(cert_path, cert),
         :ok <- eff.chmod.(cert_path, @cert_mode),
         :ok <- eff.chown.(cert_path, uid, gid),
         :ok <- eff.write_file.(key_path, key),
         :ok <- eff.chmod.(key_path, @key_mode),
         :ok <- eff.chown.(key_path, uid, gid) do
      :ok
    end
  end

  # ==========================================================================
  # acme (worldtree-scoped only)
  # ==========================================================================

  defp ensure_acme(fqdn, opts, eff) do
    if acme_zone_allowed?(fqdn, eff.acme_zones) do
      apex = apex_of(fqdn, opts)

      with {:ok, content} <- read_toml(eff) do
        case toml_acme_add_domain(content, fqdn) do
          {:unchanged, _} ->
            {:ok, :unchanged}

          {:updated, content2} ->
            content2
            |> ensure_domain_block(apex)
            |> write_and_reload(eff, fn -> :acme_requested end)

          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      {:error, {:acme_unsupported_zone, fqdn}}
    end
  end

  defp acme_zone_allowed?(fqdn, zones) do
    Enum.any?(zones, fn z -> fqdn == z or String.ends_with?(fqdn, "." <> z) end)
  end

  # ==========================================================================
  # Shared side-effect helpers
  # ==========================================================================

  # Write the (possibly unchanged) TOML then reload iff we're actually writing.
  # `on_ok` returns the success tag.
  defp write_and_reload(content, eff, on_ok) do
    case eff.write_file.(eff.gateway_toml_path, content) do
      :ok ->
        tag = on_ok.()
        eff.reload.()
        Logger.info("Gateway.Certs: #{tag}; wrote #{eff.gateway_toml_path} and reloaded")
        {:ok, tag}

      {:error, reason} = err ->
        Logger.error("Gateway.Certs: failed to write #{eff.gateway_toml_path}: #{inspect(reason)}")
        err
    end
  end

  defp ensure_cert_block(content, fqdn, cert_path, key_path) do
    if toml_has_cert?(content, fqdn) do
      content
    else
      append_block(content, render_cert_block(fqdn, cert_path, key_path))
    end
  end

  defp ensure_domain_block(content, apex) do
    if toml_has_domain?(content, apex) do
      content
    else
      append_block(content, render_domain_block(apex))
    end
  end

  defp maybe_remove_domain(content, fqdn, opts) do
    if Keyword.get(opts, :remove_domain, false) do
      toml_remove_domain(content, apex_of(fqdn, opts))
    else
      content
    end
  end

  defp cert_details(eff, cert_path) do
    with {:ok, pem} <- eff.read_file.(cert_path),
         {:ok, info} <- eff.cert_info.(pem) do
      info
    else
      _ -> %{}
    end
  end

  defp read_matches?(eff, path, expected) do
    case eff.read_file.(path) do
      {:ok, ^expected} -> true
      _ -> false
    end
  end

  defp fetch_pem(opts, key) do
    case Keyword.get(opts, key) do
      pem when is_binary(pem) and pem != "" -> {:ok, pem}
      _ -> {:error, {:missing_pem, key}}
    end
  end

  defp read_toml(eff) do
    case eff.read_file.(eff.gateway_toml_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, ""}
      {:error, _} = err -> err
    end
  end

  defp normalize_fqdn(fqdn) do
    fqdn |> String.trim() |> String.trim_trailing(".") |> String.downcase()
  end

  # ==========================================================================
  # TOML block manipulation
  #
  # gateway.toml is hand-maintained flat array-of-tables. We do header-aware
  # chunking (not a full TOML parse): every line starting with `[` begins a new
  # chunk; a chunk owns its header + following lines up to the next header. This
  # preserves formatting/comments on rewrite and is sufficient for the flat
  # `[[cert]]`/`[[domain]]`/`[acme]` shapes the gateway uses.
  # ==========================================================================

  @doc false
  def toml_has_cert?(content, host) do
    Enum.any?(chunks(content), &cert_chunk_for?(&1, host))
  end

  @doc false
  def toml_has_domain?(content, suffix) do
    Enum.any?(chunks(content), &domain_chunk_for?(&1, suffix))
  end

  @doc false
  def toml_list_certs(content) do
    for chunk <- chunks(content), match?({"cert", true}, chunk_type(chunk)) do
      %{
        host: chunk_get(chunk, "host"),
        cert_path: chunk_get(chunk, "cert"),
        key_path: chunk_get(chunk, "key")
      }
    end
  end

  defp toml_remove_cert(content, host) do
    content
    |> chunks()
    |> Enum.reject(&cert_chunk_for?(&1, host))
    |> flatten_chunks()
  end

  defp toml_remove_domain(content, suffix) do
    content
    |> chunks()
    |> Enum.reject(&domain_chunk_for?(&1, suffix))
    |> flatten_chunks()
  end

  # Add fqdn to a single-line `[acme].domains = [...]` array (or create it).
  # Returns {:updated, content} | {:unchanged, content} | {:error, :no_acme_section}.
  defp toml_acme_add_domain(content, fqdn) do
    chunks = chunks(content)

    case Enum.find_index(chunks, &match?({"acme", false}, chunk_type(&1))) do
      nil ->
        {:error, :no_acme_section}

      i ->
        {new_chunk, changed?} = acme_chunk_add(Enum.at(chunks, i), fqdn)

        if changed? do
          {:updated, chunks |> List.replace_at(i, new_chunk) |> flatten_chunks()}
        else
          {:unchanged, content}
        end
    end
  end

  defp acme_chunk_add(lines, fqdn) do
    case Enum.find_index(lines, &String.match?(&1, ~r/^\s*domains\s*=\s*\[/)) do
      nil ->
        {List.insert_at(lines, 1, ~s(domains = ["#{fqdn}"])), true}

      li ->
        existing = parse_inline_array(Enum.at(lines, li))

        if fqdn in existing do
          {lines, false}
        else
          rendered = "domains = [" <> Enum.map_join(existing ++ [fqdn], ", ", &~s("#{&1}")) <> "]"
          {List.replace_at(lines, li, rendered), true}
        end
    end
  end

  defp cert_chunk_for?(chunk, host) do
    match?({"cert", true}, chunk_type(chunk)) and chunk_get(chunk, "host") == host
  end

  defp domain_chunk_for?(chunk, suffix) do
    match?({"domain", true}, chunk_type(chunk)) and chunk_get(chunk, "suffix") == suffix
  end

  # Split content into chunks; each chunk is a list of raw lines.
  defp chunks(content) do
    content
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      if header_line?(line) do
        [[line] | acc]
      else
        case acc do
          [] -> [[line]]
          [cur | rest] -> [[line | cur] | rest]
        end
      end
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
  end

  defp flatten_chunks(chunks), do: chunks |> List.flatten() |> Enum.join("\n")

  defp header_line?(line), do: String.match?(line, ~r/^\s*\[/)

  defp chunk_type([first | _]) do
    case Regex.run(~r/^\s*\[(\[?)\s*([A-Za-z0-9_.\-]+)\s*\]?\]/, first) do
      [_, dbl, name] -> {name, dbl == "["}
      _ -> nil
    end
  end

  defp chunk_type([]), do: nil

  defp chunk_get(chunk, key) do
    Enum.find_value(chunk, fn line ->
      case Regex.run(~r/^\s*#{Regex.escape(key)}\s*=\s*"([^"]*)"/, line) do
        [_, v] -> v
        _ -> nil
      end
    end)
  end

  defp parse_inline_array(line) do
    ~r/"([^"]*)"/
    |> Regex.scan(line)
    |> Enum.map(fn [_, v] -> v end)
  end

  defp append_block(content, block) do
    base = String.trim_trailing(content, "\n")
    prefix = if base == "", do: "", else: base <> "\n\n"
    prefix <> block <> "\n"
  end

  # TOML basic string (our values contain no quotes/backslashes; escape anyway).
  defp quote_str(s) do
    escaped = s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"" <> escaped <> "\""
  end

  # ==========================================================================
  # Effects seam
  # ==========================================================================

  @doc """
  Resolve the injectable effects/config from `opts`, defaulting to the real
  system. Every entry is overridable in tests.

    * File: `:read_file/1`, `:write_file/2`, `:mkdir_p/1`, `:chmod/2`,
      `:chown/3`, `:rm_rf/1`
    * Gateway: `:reload/0`
    * Cert inspection (openssl-backed by default): `:validate_pair/2`,
      `:cert_covers/2`, `:cert_info/1`
    * Config: `:gateway_toml_path`, `:certs_dir`, `:owner` (`{uid, gid}`),
      `:acme_zones`
  """
  @spec effects(keyword()) :: map()
  def effects(opts \\ []) do
    %{
      read_file: Keyword.get(opts, :read_file, &default_read_file/1),
      write_file: Keyword.get(opts, :write_file, &default_write_file/2),
      mkdir_p: Keyword.get(opts, :mkdir_p, &File.mkdir_p/1),
      chmod: Keyword.get(opts, :chmod, &File.chmod/2),
      chown: Keyword.get(opts, :chown, &default_chown/3),
      rm_rf: Keyword.get(opts, :rm_rf, &default_rm_rf/1),
      reload: Keyword.get(opts, :reload, &default_reload/0),
      validate_pair: Keyword.get(opts, :validate_pair, &default_validate_pair/2),
      cert_covers: Keyword.get(opts, :cert_covers, &default_cert_covers/2),
      cert_info: Keyword.get(opts, :cert_info, &default_cert_info/1),
      gateway_toml_path:
        Keyword.get(
          opts,
          :gateway_toml_path,
          Application.get_env(:mjolnir, :gateway_toml_path, @default_gateway_toml)
        ),
      certs_dir:
        Keyword.get(
          opts,
          :certs_dir,
          Application.get_env(:mjolnir, :gateway_certs_dir, @default_certs_dir)
        ),
      owner: Keyword.get(opts, :owner, {@uid, @gid}),
      acme_zones:
        Keyword.get(
          opts,
          :acme_zones,
          Application.get_env(:mjolnir, :gateway_acme_zones, @default_acme_zones)
        )
    }
  end

  # ---- Default (real) effect impls -----------------------------------------

  defp default_read_file(path), do: File.read(path)

  defp default_write_file(path, contents) do
    dir = Path.dirname(path)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, contents),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _} = err ->
        _ = File.rm(tmp)
        err
    end
  end

  defp default_chown(path, uid, gid), do: :file.change_owner(path, uid, gid)

  defp default_rm_rf(path) do
    case File.rm_rf(path) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp default_reload do
    case System.cmd("systemctl", ["reload", "mjolnir-gateway"], stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Logger.warning("Gateway.Certs: 'systemctl reload mjolnir-gateway' exited #{code}: #{out}")
        :ok
    end
  rescue
    e ->
      Logger.warning("Gateway.Certs: reload command failed: #{Exception.message(e)}")
      :ok
  end

  # openssl-backed cert inspection. Never exercised by the test suite (fakes are
  # injected); runs on the real Linux gateway host.
  defp default_validate_pair(cert_pem, key_pem) do
    with {:ok, cert_pub} <- with_tmp(cert_pem, &openssl(["x509", "-in", &1, "-noout", "-pubkey"])),
         {:ok, key_pub} <- with_tmp(key_pem, &openssl(["pkey", "-in", &1, "-pubout"])) do
      if String.trim(cert_pub) == String.trim(key_pub),
        do: :ok,
        else: {:error, :key_pair_mismatch}
    end
  end

  defp default_cert_covers(cert_pem, fqdn) do
    with {:ok, sans} <- cert_sans(cert_pem) do
      if Enum.any?(sans, &san_matches?(&1, fqdn)),
        do: :ok,
        else: {:error, {:san_not_covered, fqdn, sans}}
    end
  end

  defp default_cert_info(cert_pem) do
    with {:ok, enddate} <- with_tmp(cert_pem, &openssl(["x509", "-in", &1, "-noout", "-enddate"])),
         {:ok, issuer} <- with_tmp(cert_pem, &openssl(["x509", "-in", &1, "-noout", "-issuer"])),
         {:ok, sans} <- cert_sans(cert_pem) do
      {:ok,
       %{
         not_after: enddate |> String.replace_prefix("notAfter=", "") |> String.trim(),
         issuer: issuer |> String.replace_prefix("issuer=", "") |> String.trim(),
         sans: sans
       }}
    end
  end

  defp cert_sans(cert_pem) do
    with {:ok, out} <-
           with_tmp(cert_pem, &openssl(["x509", "-in", &1, "-noout", "-ext", "subjectAltName"])) do
      sans =
        ~r/DNS:([^,\s]+)/
        |> Regex.scan(out)
        |> Enum.map(fn [_, dns] -> String.downcase(dns) end)

      {:ok, sans}
    end
  end

  defp san_matches?(san, fqdn) do
    cond do
      san == fqdn -> true
      String.starts_with?(san, "*.") -> String.ends_with?(fqdn, String.trim_leading(san, "*"))
      true -> false
    end
  end

  defp with_tmp(contents, fun) do
    path = Path.join(System.tmp_dir!(), "mjolnir-cert-#{System.unique_integer([:positive])}.pem")

    try do
      case File.write(path, contents) do
        :ok -> fun.(path)
        {:error, _} = err -> err
      end
    after
      _ = File.rm(path)
    end
  end

  defp openssl(args) do
    case System.cmd("openssl", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:openssl_exit, code, out}}
    end
  rescue
    e -> {:error, {:openssl_failed, Exception.message(e)}}
  end
end
