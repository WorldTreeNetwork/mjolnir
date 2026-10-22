defmodule Mjolnir.Deploy.ForgejoOwners do
  @moduledoc """
  Forgejo account (or one repo) → canonical base58 XID.

  One JSON file beside the deploy registry. Writes are atomic. A missing
  row means do not deploy: the caller must not fall back to `localhost`.

  Lookup is case-insensitive. A `login/repo` row wins over the account row.
  Linking is an operator action. The HTTP routes that call this module are
  loopback-only.
  """

  alias Mjolnir.Deploy.Owner

  @login ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$/

  @doc "Path of the JSON document. Override with `:forgejo_owners_path`."
  @spec path() :: String.t()
  def path do
    Application.get_env(:mjolnir, :forgejo_owners_path) || default_path()
  end

  @doc """
  XID for `owner/repo`. Repo row, then account row, else `:error`.
  """
  @spec resolve(term(), String.t()) :: {:ok, String.t()} | :error
  def resolve(repo, file \\ path())

  def resolve(repo, file) when is_binary(repo) do
    case String.split(repo, "/", parts: 2) do
      [login, name] ->
        with {:ok, login} <- name(login, :invalid_login),
             {:ok, name} <- name(name, :invalid_repo) do
          data = read(file)
          key = login <> "/" <> name

          cond do
            is_binary(data.repos[key]) -> {:ok, data.repos[key]}
            is_binary(data.accounts[login]) -> {:ok, data.accounts[login]}
            true -> :error
          end
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def resolve(_, _), do: :error

  @spec put_account(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_login | :invalid_owner}
  def put_account(login, owner_id, file \\ path()) do
    with {:ok, login} <- name(login, :invalid_login),
         {:ok, owner_id} <- owner(owner_id),
         :ok <-
           write_update(file, fn data ->
             %{data | accounts: Map.put(data.accounts, login, owner_id)}
           end) do
      {:ok, owner_id}
    end
  end

  @spec put_repo(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_login | :invalid_repo | :invalid_owner}
  def put_repo(login, repo, owner_id, file \\ path()) do
    with {:ok, login} <- name(login, :invalid_login),
         {:ok, repo} <- name(repo, :invalid_repo),
         {:ok, owner_id} <- owner(owner_id),
         :ok <-
           write_update(file, fn data ->
             %{data | repos: Map.put(data.repos, login <> "/" <> repo, owner_id)}
           end) do
      {:ok, owner_id}
    end
  end

  @spec delete_account(String.t(), String.t()) :: :ok | {:error, :invalid_login}
  def delete_account(login, file \\ path()) do
    with {:ok, login} <- name(login, :invalid_login) do
      write_update(file, fn data -> %{data | accounts: Map.delete(data.accounts, login)} end)
    end
  end

  @spec delete_repo(String.t(), String.t(), String.t()) ::
          :ok | {:error, :invalid_login | :invalid_repo}
  def delete_repo(login, repo, file \\ path()) do
    with {:ok, login} <- name(login, :invalid_login),
         {:ok, repo} <- name(repo, :invalid_repo) do
      write_update(file, fn data ->
        %{data | repos: Map.delete(data.repos, login <> "/" <> repo)}
      end)
    end
  end

  defp name(value, error) when is_binary(value) do
    trimmed = String.trim(value)

    if Regex.match?(@login, trimmed) and String.downcase(trimmed) != "resolve" do
      {:ok, String.downcase(trimmed)}
    else
      {:error, error}
    end
  end

  defp name(_, error), do: {:error, error}

  defp owner(value) do
    case Owner.parse(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_owner}
    end
  end

  defp default_path do
    registry =
      Application.get_env(:mjolnir, :deploy_state_dir, "/var/lib/mjolnir/deploy/registry")

    registry
    |> Path.dirname()
    |> Path.join("forgejo-owners.json")
  end

  defp empty, do: %{accounts: %{}, repos: %{}}

  defp read(file) do
    case File.read(file) do
      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, map} when is_map(map) ->
            %{
              accounts: string_map(map["accounts"]),
              repos: string_map(map["repos"])
            }

          _ ->
            empty()
        end

      {:error, :enoent} ->
        empty()

      _ ->
        empty()
    end
  end

  defp string_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) and is_binary(v) -> {k, v}
      {k, v} -> {to_string(k), to_string(v)}
    end)
  end

  defp string_map(_), do: %{}

  defp write_update(file, fun) do
    File.mkdir_p!(Path.dirname(file))
    next = fun.(read(file))
    write_atomic(file, next)
  end

  defp write_atomic(file, data) do
    json =
      Jason.encode!(%{
        "accounts" => data.accounts,
        "repos" => data.repos
      })

    tmp = file <> ".tmp"

    with {:ok, io} <- :file.open(tmp, [:raw, :write, :binary]),
         :ok <- :file.write(io, json),
         :ok <- :file.sync(io),
         :ok <- :file.close(io),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      error ->
        _ = File.rm(tmp)
        {:error, error}
    end
  end
end
