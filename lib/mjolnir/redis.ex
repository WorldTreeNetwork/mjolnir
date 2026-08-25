defmodule Mjolnir.Redis do
  @moduledoc """
  Host Redis sidecar secrets (ADR 0007).

  Does not start Redis — that is systemd. Operator command only:
  `mix mjolnir.redis.ensure --slug hypersigil-api`.
  """

  require Logger

  @slug_re ~r/^[a-z0-9][a-z0-9_-]*$/

  @type result :: %{slug: String.t(), url: String.t()}

  @doc "REDIS_URL for overlay TCP. Password is URI-encoded."
  @spec redis_url(String.t(), String.t()) :: String.t()
  def redis_url(password, listen_ip)
      when is_binary(password) and is_binary(listen_ip) do
    "redis://:#{URI.encode_www_form(password)}@#{listen_ip}:6379/0"
  end

  @doc """
  Ensure `REDIS_URL` in deploy secrets for `slug`.

  Options: `:rotate` (boolean). Merges; does not drop `DATABASE_URL`.
  """
  @spec ensure(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def ensure(slug, opts \\ []) when is_binary(slug) do
    rotate? = Keyword.get(opts, :rotate, false)

    with :ok <- validate_slug(slug),
         {:ok, password, origin} <- password_for(rotate?),
         :ok <- persist_password(password, origin),
         url <- redis_url(password, listen_ip()),
         :ok <- write_secret(slug, url) do
      maybe_restart(origin)
      Logger.info("Redis: REDIS_URL ready (#{origin}, slug=#{slug})")
      {:ok, %{slug: slug, url: url}}
    end
  end

  defp validate_slug(s) do
    if Regex.match?(@slug_re, s), do: :ok, else: {:error, {:invalid_slug, s}}
  end

  defp listen_ip do
    Application.get_env(:mjolnir, :host_api_ip, "10.200.0.1")
  end

  defp pass_file do
    Application.get_env(:mjolnir, :redis_pass_file, "/etc/mjolnir/redis.pass")
  end

  defp pass_conf do
    Application.get_env(:mjolnir, :redis_pass_conf, "/etc/mjolnir/redis.pass.conf")
  end

  defp secrets_dir do
    Application.get_env(:mjolnir, :deploy_secrets_dir, "/var/lib/mjolnir/deploy/secrets")
  end

  defp password_for(true), do: {:ok, gen_password(), :rotated}

  defp password_for(false) do
    path = pass_file()

    case File.read(path) do
      {:ok, bin} ->
        pass = String.trim(bin)

        if pass == "", do: {:ok, gen_password(), :rewritten}, else: {:ok, pass, :existing}

      {:error, :enoent} ->
        {:ok, gen_password(), :created}

      {:error, reason} ->
        {:error, {:read_pass, reason}}
    end
  end

  defp gen_password do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end

  defp persist_password(_password, :existing), do: :ok

  defp persist_password(password, _origin) do
    file = pass_file()
    conf = pass_conf()

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, password <> "\n"),
         :ok <- File.chmod(file, 0o600),
         :ok <- File.write(conf, "requirepass #{password}\n"),
         :ok <- File.chmod(conf, 0o640) do
      :ok
    end
  end

  defp write_secret(slug, url) do
    path = Path.join(secrets_dir(), slug <> ".json")

    existing =
      case File.read(path) do
        {:ok, bin} ->
          case Jason.decode(bin) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end

    body = existing |> Map.put("REDIS_URL", url) |> Jason.encode!()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, body),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp maybe_restart(origin) when origin in [:created, :rotated, :rewritten] do
    unit = "/etc/systemd/system/mjolnir-redis.service"

    if File.exists?(unit) do
      System.cmd("systemctl", ["restart", "mjolnir-redis"], stderr_to_stdout: true)
    end

    :ok
  end

  defp maybe_restart(:existing), do: :ok
end
