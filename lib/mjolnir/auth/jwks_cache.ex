defmodule Mjolnir.Auth.JwksCache do
  @moduledoc """
  Validated issuer-bound JWKS storage, separate from the edge-key bundle.

  There is no key-age TTL: the last successfully persisted issuer document
  replaces the set. Token expiry is checked by the token verifier.
  """
  import Bitwise

  @filename "hosted-jwks.json"

  def path(opts) do
    with {:ok, dir} <- Mjolnir.Auth.EdgeKeys.safe_auth_dir(opts) do
      {:ok, Path.join(dir, @filename)}
    end
  end

  def load(opts) do
    with {:ok, path} <- path(opts),
         :ok <- check_mode(Path.dirname(path), :directory, 0o700),
         :ok <- check_mode(path, :regular, 0o600),
         {:ok, bytes} <- File.read(path),
         {:ok, envelope} <- Jason.decode(bytes),
         %{"version" => 1, "issuer" => issuer, "jwks_url" => url, "jwks" => document} <- envelope,
         true <- issuer == normalize(opts[:issuer]) and url == normalize(opts[:jwks_url]),
         {:ok, signers} <- validate(document) do
      {:ok, signers}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_cache_binding}
    end
  end

  @doc "Validate, bind and atomically persist a complete issuer document."
  def persist(document, opts) do
    with {:ok, signers} <- validate(document),
         {:ok, path} <- path(opts),
         :ok <- ensure_directory(Path.dirname(path)),
         :ok <- check_destination(path),
         {:ok, bytes} <-
           Jason.encode(%{
             "version" => 1,
             "issuer" => normalize(opts[:issuer]),
             "jwks_url" => normalize(opts[:jwks_url]),
             "jwks" => document
           }),
         :ok <- atomic_write(path, bytes) do
      {:ok, signers}
    end
  end

  def validate(%{"keys" => keys}) when is_list(keys) and keys != [] do
    with :ok <- unique_kids(keys),
         {:ok, signers} <- parse_keys(keys),
         true <- map_size(signers) > 0 do
      {:ok, signers}
    else
      {:error, _} = error -> error
      _ -> {:error, :no_usable_keys}
    end
  end

  def validate(_), do: {:error, :invalid_jwks}

  defp unique_kids(keys) do
    Enum.reduce_while(keys, %{}, fn
      %{"kid" => kid} = key, seen when is_binary(kid) and kid != "" ->
        case Map.fetch(seen, kid) do
          {:ok, prior} when prior != key -> {:halt, {:error, :conflicting_kid}}
          _ -> {:cont, Map.put(seen, kid, key)}
        end

      _, _ ->
        {:halt, {:error, :invalid_key}}
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp parse_keys(keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, signers} ->
      case parse_key(key) do
        {:ok, signer} -> {:cont, {:ok, Map.put(signers, key["kid"], signer)}}
        :skip -> {:cont, {:ok, signers}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp parse_key(key) do
    alg = key["alg"]

    signing? =
      key["use"] in [nil, "sig"] and
        (is_nil(key["key_ops"]) or "verify" in key["key_ops"])

    supported? =
      case {key["kty"], alg} do
        {"RSA", alg} when alg in ~w(RS256 RS384 RS512 PS256 PS384 PS512) -> true
        {"EC", alg} when alg in ~w(ES256 ES384 ES512) -> true
        {"OKP", alg} when alg in ~w(EdDSA Ed25519 Ed448) -> true
        _ -> false
      end

    if signing? and supported? do
      signer = Joken.Signer.create(alg, key)
      # Force JOSE to parse/export the public key before trusting the entry.
      {_type, public} = JOSE.JWK.to_public_map(signer.jwk)
      if Map.has_key?(public, "kty"), do: {:ok, signer}, else: {:error, :invalid_key}
    else
      :skip
    end
  rescue
    _ -> {:error, :invalid_key}
  catch
    _, _ -> {:error, :invalid_key}
  end

  defp normalize(value) when is_binary(value), do: String.trim_trailing(value, "/")

  defp ensure_directory(dir) do
    case File.lstat(dir) do
      {:error, :enoent} ->
        with :ok <- install(["-d", "-m", "700", dir]) do
          check_mode(dir, :directory, 0o700)
        end

      {:ok, _} ->
        check_mode(dir, :directory, 0o700)

      {:error, _} = error ->
        error
    end
  end

  defp check_destination(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _ -> check_mode(path, :regular, 0o600)
    end
  end

  defp check_mode(path, type, expected) do
    case File.lstat(path) do
      {:ok, %{type: ^type, mode: mode}} when band(mode, 0o7777) == expected -> :ok
      {:ok, _} -> {:error, :bad_permissions}
      {:error, _} = error -> error
    end
  end

  # Match EdgeKeys' creation contract: restrictive modes at creation rather
  # than exposing a file through the process-wide umask before chmod.
  defp install(args) do
    case System.find_executable("install") do
      nil ->
        {:error, :secure_create_failed}

      executable ->
        case System.cmd(executable, args, stderr_to_stdout: true) do
          {_, 0} -> :ok
          _ -> {:error, :secure_create_failed}
        end
    end
  end

  defp atomic_write(path, bytes) do
    tmp = path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    try do
      with :ok <- install(["-m", "600", "/dev/null", tmp]),
           :ok <- check_mode(tmp, :regular, 0o600),
           {:ok, io} <- File.open(tmp, [:write, :binary]) do
        result =
          try do
            with :ok <- IO.binwrite(io, bytes), do: :file.sync(io)
          after
            File.close(io)
          end

        with :ok <- result, do: File.rename(tmp, path)
      end
    after
      File.rm(tmp)
    end
  end
end
