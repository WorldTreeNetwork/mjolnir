defmodule Mjolnir.Relay.Mint do
  @moduledoc false

  require Logger

  @segment ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @default_ttl 3600

  def issue(caller, room, participant, body, opts \\ []) do
    with :ok <- principal(caller),
         :ok <- segment(room),
         :ok <- segment(participant),
         {:ok, asked} <- ttl_field(body),
         {:ok, kind} <- kind_field(body),
         {:ok, env} <- read_env(opts),
         :ok <- configured(env),
         {:ok, ttl} <- clamp_ttl(asked, env.ceiling),
         {:ok, owner} <- owner(caller.sub),
         :ok <- key_mode(opts),
         {:ok, jwk, kid} <- load_key(opts) do
      now = System.system_time(:second)
      exp = now + ttl
      jti = jti()
      root = root_for(owner, room, kind)
      publish = "#{participant}/**"

      case sign(jwk, kid, root, publish, now, exp, jti) do
        token when is_binary(token) ->
          Logger.info(
            "relay mint sub=#{caller.sub} owner=#{owner} room=#{room} participant=#{participant} kind=#{kind} jti=#{jti} exp=#{exp}"
          )

          {:ok,
           %{
             token: token,
             expires: exp,
             root: root,
             publish: publish,
             subscribe: "**",
             relay_host: env.host,
             kind: Atom.to_string(kind)
           }}

        _ ->
          {:error, 503, "relay_unavailable"}
      end
    end
  end

  def principal(%{kind: :user, scopes: scopes}) when is_binary(scopes) do
    if "relay:join" in String.split(scopes, " ", trim: true),
      do: :ok,
      else: {:error, 403, "forbidden"}
  end

  def principal(_), do: {:error, 403, "forbidden"}

  defp segment(value) when is_binary(value) do
    if Regex.match?(@segment, value), do: :ok, else: {:error, 400, "bad_segment"}
  end

  defp segment(_), do: {:error, 400, "bad_segment"}

  defp ttl_field(body) when body == %{} or body == nil, do: {:ok, nil}

  defp ttl_field(%{"ttl" => ttl}) when is_integer(ttl), do: {:ok, ttl}

  defp ttl_field(%{"ttl" => _}), do: {:error, 400, "bad_ttl"}

  defp ttl_field(_), do: {:ok, nil}

  # After segment and ttl type, before the env file. A bad kind is 400
  # whether or not the relay is configured. Omitted means protected.
  # Only the JSON body is read. The value is compared exactly.
  defp kind_field(body) when body == %{} or body == nil, do: {:ok, :protected}

  defp kind_field(body) when is_map(body) do
    case Map.fetch(body, "kind") do
      :error -> {:ok, :protected}
      {:ok, "open"} -> {:ok, :open}
      {:ok, "protected"} -> {:ok, :protected}
      {:ok, _} -> {:error, 400, "bad_kind"}
    end
  end

  defp kind_field(_), do: {:ok, :protected}

  defp root_for(owner, room, :open), do: "t/#{owner}/~open/#{room}"
  defp root_for(owner, room, :protected), do: "t/#{owner}/#{room}"

  defp clamp_ttl(nil, ceiling) when ceiling < @default_ttl, do: {:ok, ceiling}
  defp clamp_ttl(nil, _), do: {:ok, @default_ttl}
  defp clamp_ttl(ttl, _) when ttl <= 0, do: {:error, 400, "bad_ttl"}
  defp clamp_ttl(ttl, ceiling) when ttl > ceiling, do: {:error, 400, "bad_ttl"}
  defp clamp_ttl(ttl, _), do: {:ok, ttl}

  defp configured(%{enabled: "true", host: host}) when is_binary(host) and host != "", do: :ok
  defp configured(_), do: {:error, 503, "relay_unavailable"}

  defp owner(sub) do
    case Mjolnir.Deploy.Owner.mint_owner(sub) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, 403, "forbidden"}
    end
  end

  defp read_env(opts) do
    path =
      Keyword.get(opts, :env_path) ||
        Application.get_env(:mjolnir, :relay_mint_env_path) ||
        "/etc/mjolnir-relay/relay.env"

    case File.read(path) do
      {:ok, text} ->
        map =
          text
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, acc ->
            case String.split(line, "=", parts: 2) do
              [k, v] -> Map.put(acc, String.trim(k), unquote_env(v))
              _ -> acc
            end
          end)

        with {:ok, ceiling} <- ceiling(map) do
          {:ok,
           %{
             enabled: Map.get(map, "MJOLNIR_RELAY_ENABLED"),
             host: Map.get(map, "MJOLNIR_RELAY_HOST"),
             ceiling: ceiling
           }}
        end

      {:error, _} ->
        {:error, 503, "relay_unavailable"}
    end
  end

  defp unquote_env(value) do
    trimmed = String.trim(to_string(value))

    case trimmed do
      <<quote::utf8, rest::binary>> when quote in [?", ?'] ->
        size = byte_size(rest)

        if size > 0 and binary_part(rest, size - 1, 1) == <<quote>> do
          binary_part(rest, 0, size - 1)
        else
          trimmed
        end

      _ ->
        trimmed
    end
  end

  defp ceiling(map) do
    case Map.fetch(map, "MJOLNIR_RELAY_TOKEN_MAX_TTL") do
      :error ->
        {:ok, 3600}

      {:ok, raw} ->
        case Integer.parse(raw) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, 503, "relay_unavailable"}
        end
    end
  end

  def key_mode(opts) do
    path = key_path(opts)

    expected =
      Keyword.get(opts, :uid) ||
        Application.get_env(:mjolnir, :relay_mint_uid, 0)

    with {:ok, file} <- File.stat(path),
         {:ok, dir} <- File.stat(Path.dirname(path)),
         true <- file.uid == expected and dir.uid == expected,
         true <- no_group_other_write(dir.mode) and private_file(file.mode) do
      :ok
    else
      _ -> {:error, 503, "relay_unavailable"}
    end
  end

  defp no_group_other_write(mode), do: Bitwise.band(mode, 0o022) == 0
  defp private_file(mode), do: Bitwise.band(mode, 0o077) == 0

  defp key_path(opts) do
    Keyword.get(opts, :key_path) ||
      Application.get_env(:mjolnir, :relay_mint_key_path) ||
      "/var/lib/mjolnir/relay-mint/current.jwk"
  end

  defp load_key(opts) do
    path = key_path(opts)

    with {:ok, raw} <- File.read(path),
         {:ok, map} <- Jason.decode(raw),
         true <- map["kty"] == "OKP" and map["crv"] == "Ed25519" and map["alg"] == "EdDSA",
         kid when is_binary(kid) <- map["kid"],
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, kid),
         true <- is_binary(map["x"]) and is_binary(map["d"]) do
      try do
        jwk = JOSE.JWK.from_map(map)
        {:ok, jwk, kid}
      rescue
        _ -> {:error, 503, "relay_unavailable"}
      end
    else
      _ -> {:error, 503, "relay_unavailable"}
    end
  end

  defp sign(jwk, kid, root, publish, iat, exp, jti) do
    payload = %{
      "root" => root,
      "publish" => [publish],
      "subscribe" => ["**"],
      "iat" => iat,
      "exp" => exp,
      "jti" => jti
    }

    try do
      {_, jws} = JOSE.JWT.sign(jwk, %{"alg" => "EdDSA", "kid" => kid}, payload)
      {_, token} = JOSE.JWS.compact(jws)
      token
    rescue
      _ -> :error
    end
  end

  defp jti do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
