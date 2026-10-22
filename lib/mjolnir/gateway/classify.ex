defmodule Mjolnir.Gateway.Classify do
  @moduledoc """
  Host classification mirrored from `mjolnir-gateway`, without a control call.

  The issuer uses this before HTTP-01 on a site alias. `Local` and `Iroh`
  never reach the sites resolver. `Reject` and `Parked` do. A `[[cert]]` is
  not an apex.

  The base file is `:gateway_toml_path` (default `/etc/mjolnir/gateway.toml`).
  Drop-ins are `[[route]]` and `[[alias]]` only, from the sibling `gateway.d`
  or `GATEWAY_CONFIG_D`. A missing base file is an empty route table
  (`:reject`). Any other failure to read or classify the base file is
  `{:error, :gateway_config_unreadable}`.

  Tests pin the base path with `Process.put(:mjolnir_gateway_toml_path, path)`
  so a developer `gateway.toml` cannot change the suite. While that key is
  set, drop-ins come from the sibling directory unless
  `:mjolnir_gateway_config_d` is set too.
  """

  @default_toml "/etc/mjolnir/gateway.toml"
  @z32_alphabet "ybndrfg8ejkmcpqxot1uwisza345h769"

  @type kind :: :local | :iroh | :parked | :reject

  @doc """
  Classify `host` using the gateway config on disk.

  Returns `{:ok, kind}` or `{:error, :gateway_config_unreadable}`.
  """
  @spec for_host(String.t()) :: {:ok, kind()} | {:error, :gateway_config_unreadable}
  def for_host(host) when is_binary(host) do
    path = toml_path()

    case File.read(path) do
      {:error, :enoent} ->
        classify(host, "", [])

      {:error, _} ->
        {:error, :gateway_config_unreadable}

      {:ok, base} ->
        classify(host, base, read_dropins(dropin_dir(path)))
    end
  end

  @doc """
  Classify `host` against an in-memory base document and drop-in documents.

  `dropins` are toml strings. A drop-in that declares an apex is ignored.
  """
  @spec classify(String.t(), String.t(), [String.t()]) ::
          {:ok, kind()} | {:error, :gateway_config_unreadable}
  def classify(host, base_toml, dropins \\ [])

  def classify(host, base_toml, dropins)
      when is_binary(host) and is_binary(base_toml) and is_list(dropins) do
    try do
      do_classify(host, base_toml, dropins)
    rescue
      ArgumentError -> {:error, :gateway_config_unreadable}
    end
  end

  defp do_classify(host, base_toml, dropins) do
    base_chunks = chunks(base_toml)

    with {:ok, apexes} <- take_domains(base_chunks) do
      {routes, aliases} =
        Enum.reduce(dropins, collect(base_chunks, apexes, [], []), fn text, {routes, aliases} ->
          collect(chunks(text), apexes, routes, aliases)
        end)

      {:ok, disposition(normalize_host(host), apexes, routes, aliases)}
    end
  end

  defp toml_path do
    Process.get(:mjolnir_gateway_toml_path) ||
      Application.get_env(:mjolnir, :gateway_toml_path, @default_toml)
  end

  defp dropin_dir(base_path) do
    cond do
      is_binary(Process.get(:mjolnir_gateway_config_d)) ->
        Process.get(:mjolnir_gateway_config_d)

      is_binary(Process.get(:mjolnir_gateway_toml_path)) ->
        Path.join(Path.dirname(base_path), "gateway.d")

      true ->
        case System.get_env("GATEWAY_CONFIG_D") do
          dir when is_binary(dir) and dir != "" -> dir
          _ -> Path.join(Path.dirname(base_path), "gateway.d")
        end
    end
  end

  defp read_dropins(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".toml"))
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          case File.read(Path.join(dir, name)) do
            {:ok, text} when is_binary(text) -> [text]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp disposition(host, apexes, routes, aliases) do
    ordered = Enum.sort_by(apexes, fn apex -> -byte_size(apex.suffix) end)

    case match_host(host, ordered) do
      nil ->
        :reject

      {apex, ""} ->
        cond do
          local?(routes, apex.suffix, "") -> :local
          apex.fallthrough == :parked -> :parked
          true -> :reject
        end

      {apex, sub} ->
        cond do
          local?(routes, apex.suffix, sub) -> :local
          alias?(aliases, apex.suffix, sub) -> :iroh
          apex.fallthrough == :iroh -> :iroh
          apex.fallthrough == :parked -> :parked
          true -> :reject
        end
    end
  end

  defp match_host(host, apexes) do
    Enum.find_value(apexes, fn apex ->
      cond do
        host == apex.suffix ->
          {apex, ""}

        String.ends_with?(host, "." <> apex.suffix) ->
          {apex, String.replace_suffix(host, "." <> apex.suffix, "")}

        true ->
          nil
      end
    end)
  end

  defp local?(routes, apex, sub) do
    Enum.any?(routes, &(&1.apex == apex and &1.subdomain == sub))
  end

  defp alias?(aliases, apex, sub) do
    Enum.any?(aliases, &(&1.apex == apex and &1.subdomain == sub))
  end

  defp normalize_host(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/:\d+$/, "")
    |> String.trim_trailing(".")
  end

  defp take_domains(chunks) do
    Enum.reduce_while(chunks, [], fn chunk, acc ->
      case chunk_type(chunk) do
        {"domain", true} ->
          case domain_from(chunk, acc) do
            :duplicate -> {:cont, acc}
            {:ok, apex} -> {:cont, [apex | acc]}
            {:error, _} = err -> {:halt, err}
          end

        _ ->
          {:cont, acc}
      end
    end)
    |> case do
      {:error, _} = err -> err
      apexes -> {:ok, Enum.reverse(apexes)}
    end
  end

  defp domain_from(chunk, acc) do
    case chunk_get(chunk, "suffix") do
      nil ->
        {:error, :gateway_config_unreadable}

      suffix ->
        suffix = String.downcase(suffix)

        cond do
          String.contains?(suffix, "*") or not ascii_fqdn?(suffix) ->
            {:error, :gateway_config_unreadable}

          Enum.any?(acc, &(&1.suffix == suffix)) ->
            :duplicate

          true ->
            case fallthrough_of(chunk) do
              {:ok, kind} -> {:ok, %{suffix: suffix, fallthrough: kind}}
              {:error, _} = err -> err
            end
        end
    end
  end

  defp fallthrough_of(chunk) do
    case chunk_get(chunk, "fallthrough") do
      nil -> {:ok, :iroh}
      "iroh" -> {:ok, :iroh}
      "none" -> {:ok, :none}
      "parked" -> {:ok, :parked}
      _ -> {:error, :gateway_config_unreadable}
    end
  end

  # Routes and aliases only. Domain chunks are ignored so a drop-in cannot
  # add an apex, and a bad domain inside a drop-in is not fatal.
  defp collect(chunks, apexes, routes, aliases) do
    Enum.reduce(chunks, {routes, aliases}, fn chunk, {routes, aliases} ->
      case chunk_type(chunk) do
        {"route", true} ->
          {maybe_route(chunk, apexes, routes), aliases}

        {"alias", true} ->
          {routes, maybe_alias(chunk, apexes, aliases)}

        _ ->
          {routes, aliases}
      end
    end)
  end

  defp maybe_route(chunk, apexes, routes) do
    apex = down(chunk_get(chunk, "apex"))
    sub = down(chunk_get(chunk, "subdomain"))
    backend = chunk_get(chunk, "backend")

    cond do
      apex == nil or sub == nil or not declared?(apexes, apex) ->
        routes

      sub != "" and not ascii_name?(sub) ->
        routes

      not socket_addr?(backend) ->
        routes

      Enum.any?(routes, &(&1.apex == apex and &1.subdomain == sub)) ->
        routes

      true ->
        routes ++ [%{apex: apex, subdomain: sub}]
    end
  end

  defp maybe_alias(chunk, apexes, aliases) do
    apex = down(chunk_get(chunk, "apex"))
    sub = down(chunk_get(chunk, "subdomain"))
    node = chunk_get(chunk, "node")

    cond do
      apex == nil or sub == nil or node == nil or not declared?(apexes, apex) ->
        aliases

      not ascii_name?(sub) or not z32_node?(node) ->
        aliases

      Enum.any?(aliases, &(&1.apex == apex and &1.subdomain == sub)) ->
        aliases

      true ->
        aliases ++ [%{apex: apex, subdomain: sub}]
    end
  end

  defp declared?(apexes, suffix), do: Enum.any?(apexes, &(&1.suffix == suffix))

  defp down(nil), do: nil
  defp down(value), do: String.downcase(value)

  defp socket_addr?(nil), do: false

  defp socket_addr?(value) do
    case Regex.run(~r/^(\[[^\]]+\]|[^:]+):(\d+)$/, value) do
      [_, host, port] when host != "" ->
        case Integer.parse(port) do
          {n, ""} when n >= 0 and n <= 65_535 -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp ascii_fqdn?(value) do
    byte_size(value) > 0 and byte_size(value) <= 253 and ascii_name?(value)
  end

  defp ascii_name?(value) do
    byte_size(value) > 0 and byte_size(value) <= 253 and
      not String.starts_with?(value, ".") and not String.ends_with?(value, ".") and
      value |> String.split(".") |> Enum.all?(&ascii_label?/1)
  end

  defp ascii_label?(label) do
    n = byte_size(label)

    n > 0 and n <= 63 and not String.starts_with?(label, "-") and
      not String.ends_with?(label, "-") and String.match?(label, ~r/^[a-z0-9-]+$/)
  end

  # z-base-32, 32 bytes. The zeros vector is 52 `y`s. A bad node is skipped,
  # the same way the gateway loader skips it.
  defp z32_node?(node) when is_binary(node) do
    try do
      bits =
        Enum.reduce(:binary.bin_to_list(node), <<>>, fn byte, acc ->
          case :binary.match(@z32_alphabet, <<byte>>) do
            {idx, 1} -> <<acc::bitstring, idx::5>>
            _ -> throw(:bad)
          end
        end)

      nbytes = div(bit_size(bits), 8)
      <<bytes::binary-size(nbytes), _rest::bitstring>> = bits
      byte_size(bytes) == 32
    catch
      :bad -> false
    end
  end

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
      case Regex.run(~r/^\s*#{Regex.escape(key)}\s*=\s*(.*)$/, line) do
        [_, raw] -> parse_toml_value(String.trim(raw))
        _ -> nil
      end
    end)
  end

  defp parse_toml_value("\"" <> rest), do: parse_basic_string(rest, "")
  defp parse_toml_value("'" <> rest), do: parse_literal_string(rest)

  defp parse_toml_value(bare) do
    bare
    |> String.replace(~r/\s+#.*$/, "")
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp parse_literal_string(rest) do
    case String.split(rest, "'", parts: 2) do
      [inner, _] -> inner
      _ -> nil
    end
  end

  defp parse_basic_string("\\" <> rest, acc) do
    case rest do
      "\\" <> more -> parse_basic_string(more, acc <> "\\")
      "\"" <> more -> parse_basic_string(more, acc <> "\"")
      "n" <> more -> parse_basic_string(more, acc <> "\n")
      "t" <> more -> parse_basic_string(more, acc <> "\t")
      _ -> nil
    end
  end

  defp parse_basic_string("\"" <> _rest, acc), do: acc

  defp parse_basic_string(<<char::utf8, rest::binary>>, acc),
    do: parse_basic_string(rest, acc <> <<char::utf8>>)

  defp parse_basic_string("", _acc), do: nil
end
