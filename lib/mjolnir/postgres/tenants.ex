defmodule Mjolnir.Postgres.Tenants do
  @moduledoc """
  Declared tenant databases on the OTP Postgres sidecar (ADR 0004).

  Not called from `Bootstrap`. Operator command / declared list only.
  Tenant LOGIN roles stay out of `pg_ident.conf`.
  """

  require Logger

  alias Mjolnir.Postgres.{Config, Server}

  @ident_re ~r/^[a-z_][a-z0-9_]*$/
  @overlay_cidr "10.200.0.0/10"

  @type tenant :: %{name: String.t(), slug: String.t()}

  @doc "Tenants recorded in `:pg_tenants_file`."
  @spec list() :: [tenant()]
  def list, do: list(Config.resolve())

  @spec list(Config.t()) :: [tenant()]
  def list(%Config{} = config) do
    case File.read(config.tenants_file) do
      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, list} when is_list(list) ->
            Enum.flat_map(list, &decode_tenant/1)

          _ ->
            []
        end

      {:error, :enoent} ->
        []

      {:error, _} ->
        []
    end
  end

  @doc """
  Idempotently create database + LOGIN role and write deploy secrets.

  Options: `:slug` (default `name`), `:rotate` (boolean).
  """
  @spec ensure(String.t(), keyword()) :: {:ok, tenant()} | {:error, term()}
  def ensure(name, opts \\ []) when is_binary(name) do
    with :ok <- validate_ident(name) do
      config = Config.resolve()
      slug = Keyword.get(opts, :slug, name)
      rotate? = Keyword.get(opts, :rotate, false)

      with :ok <- validate_slug(slug),
           {:ok, password, origin} <- password_for(config, slug, rotate?),
           :ok <- provision(config, name, password),
           :ok <- write_secret(config, name, slug, password),
           :ok <- remember(config, name, slug),
           :ok <- maybe_reload_hba() do
        Logger.info("Postgres.Tenants: #{name} ready (#{origin}, slug=#{slug})")
        {:ok, %{name: name, slug: slug}}
      end
    end
  end

  @doc "Ensure every tenant listed in `:pg_tenants_file`."
  @spec ensure_declared() :: :ok | {:error, term()}
  def ensure_declared do
    Enum.reduce_while(list(), :ok, fn %{name: name, slug: slug}, _ ->
      case ensure(name, slug: slug) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp decode_tenant(%{"name" => name} = row) when is_binary(name) do
    slug = Map.get(row, "slug", name)
    [%{name: name, slug: slug}]
  end

  defp decode_tenant(%{name: name} = row) when is_binary(name) do
    [%{name: name, slug: Map.get(row, :slug, name)}]
  end

  defp decode_tenant(_), do: []

  defp validate_ident(s) when is_binary(s) do
    if Regex.match?(@ident_re, s), do: :ok, else: {:error, {:invalid_ident, s}}
  end

  defp validate_ident(s), do: {:error, {:invalid_ident, s}}

  defp validate_slug(s) when is_binary(s) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, s),
      do: :ok,
      else: {:error, {:invalid_slug, s}}
  end

  defp validate_slug(s), do: {:error, {:invalid_slug, s}}

  defp password_for(config, slug, rotate?) do
    path = secret_path(config, slug)

    cond do
      rotate? ->
        {:ok, gen_password(), :rotated}

      File.exists?(path) ->
        case Jason.decode(File.read!(path)) do
          {:ok, %{"DATABASE_URL" => url}} ->
            case URI.parse(url) do
              %URI{userinfo: userinfo} when is_binary(userinfo) ->
                case String.split(userinfo, ":", parts: 2) do
                  [_user, pass] -> {:ok, URI.decode_www_form(pass), :existing}
                  _ -> {:ok, gen_password(), :rewritten}
                end

              _ ->
                {:ok, gen_password(), :rewritten}
            end

          _ ->
            {:ok, gen_password(), :rewritten}
        end

      true ->
        {:ok, gen_password(), :created}
    end
  end

  defp gen_password do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end

  defp provision(config, name, password) do
    with_admin_conn(config, "postgres", fn conn ->
      with :ok <- ensure_role(conn, name, password),
           :ok <- ensure_database(conn, name),
           :ok <- lock_hotel(conn, config, name) do
        :ok
      end
    end)
  end

  defp ensure_role(conn, name, password) do
    case Postgrex.query(conn, "SELECT 1 FROM pg_roles WHERE rolname = $1", [name]) do
      {:ok, %{num_rows: 0}} ->
        sql = ~s|CREATE ROLE "#{name}" LOGIN PASSWORD $1|

        case Postgrex.query(conn, sql, [password]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:create_role, reason}}
        end

      {:ok, _} ->
        sql = ~s|ALTER ROLE "#{name}" LOGIN PASSWORD $1|

        case Postgrex.query(conn, sql, [password]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:alter_role, reason}}
        end

      {:error, reason} ->
        {:error, {:check_role, reason}}
    end
  end

  defp ensure_database(conn, name) do
    case Postgrex.query(conn, "SELECT 1 FROM pg_database WHERE datname = $1", [name]) do
      {:ok, %{num_rows: 0}} ->
        sql = ~s|CREATE DATABASE "#{name}" OWNER "#{name}"|

        case Postgrex.query(conn, sql, []) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:create_database, reason}}
        end

      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, {:check_database, reason}}
    end
  end

  defp lock_hotel(conn, config, name) do
    dbs =
      [config.db_name | Enum.map(list(config), & &1.name)]
      |> Enum.uniq()
      |> Kernel.++([name])
      |> Enum.uniq()

    Enum.reduce_while(dbs, :ok, fn db, _ ->
      stmts = [
        ~s|REVOKE CONNECT ON DATABASE "#{db}" FROM PUBLIC|,
        if(db == config.db_name,
          do: ~s|GRANT CONNECT ON DATABASE "#{db}" TO "#{config.bootstrap_role}"|,
          else: nil
        ),
        if(db == config.db_name,
          do:
            Enum.map(config.roles -- [config.bootstrap_role], fn role ->
              ~s|GRANT CONNECT ON DATABASE "#{db}" TO "#{role}"|
            end),
          else: []
        ),
        if(db == name,
          do: [
            ~s|GRANT CONNECT ON DATABASE "#{db}" TO "#{name}"|,
            ~s|GRANT CONNECT ON DATABASE "#{db}" TO "#{config.bootstrap_role}"|
          ],
          else: nil
        )
      ]

      case run_statements(conn, List.flatten(stmts) |> Enum.reject(&is_nil/1)) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp run_statements(conn, statements) do
    Enum.reduce_while(statements, :ok, fn sql, _ ->
      case Postgrex.query(conn, sql, []) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:ddl, sql, reason}}}
      end
    end)
  end

  @doc """
  `postgres://<ident>:<pass>@<host>:5432/<ident>` — overlay TCP, never a
  Unix socket, never the public NIC.
  """
  @spec database_url(String.t(), String.t(), String.t()) :: String.t()
  def database_url(name, password, listen_ip)
      when is_binary(name) and is_binary(password) and is_binary(listen_ip) do
    userinfo = URI.encode_www_form(name) <> ":" <> URI.encode_www_form(password)
    "postgres://#{userinfo}@#{listen_ip}:5432/#{URI.encode_www_form(name)}"
  end

  defp write_secret(config, name, slug, password) do
    ip = config.tenant_listen_ip || Application.get_env(:mjolnir, :host_api_ip, "10.200.0.1")
    url = database_url(name, password, ip)
    path = secret_path(config, slug)

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

    body = existing |> Map.put("DATABASE_URL", url) |> Jason.encode!()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, body),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp remember(config, name, slug) do
    tenants =
      config
      |> list()
      |> Enum.reject(&(&1.name == name))
      |> Kernel.++([%{name: name, slug: slug}])

    payload = Enum.map(tenants, fn t -> %{"name" => t.name, "slug" => t.slug} end)

    with :ok <- File.mkdir_p(Path.dirname(config.tenants_file)),
         :ok <- File.write(config.tenants_file, Jason.encode!(payload)),
         :ok <- File.chmod(config.tenants_file, 0o600) do
      :ok
    end
  end

  defp maybe_reload_hba do
    if Process.whereis(Server), do: Server.reload_hba(), else: :ok
  end

  defp secret_path(config, slug), do: Path.join(config.deploy_secrets_dir, slug <> ".json")

  defp with_admin_conn(config, database, fun) do
    opts = [
      socket_dir: config.socket_dir,
      username: config.bootstrap_role,
      database: database,
      backoff_type: :stop,
      pool_size: 1
    ]

    case Postgrex.start_link(opts) do
      {:ok, conn} ->
        try do
          fun.(conn)
        rescue
          e -> {:error, {:tenant_exception, e}}
        after
          GenServer.stop(conn, :normal, 5_000)
        end

      {:error, reason} ->
        {:error, {:connect, database, reason}}
    end
  end

  def overlay_cidr, do: @overlay_cidr
end
