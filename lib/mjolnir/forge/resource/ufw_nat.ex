defmodule Mjolnir.Forge.Resource.UfwNat do
  @moduledoc """
  Resource kind: a NAT rule block in `/etc/ufw/before.rules`.

  Content shape: `%{rules: binary()}`.

  ## Why this exists

  Raw `iptables -t nat` rules get wiped on `ufw reload`. The correct way to
  persist NAT on a ufw-managed host is to embed the rules in the `*nat` section
  of `/etc/ufw/before.rules`. This kind manages that section.

  ## Marker strategy

  Each resource instance owns a marker-delimited block inside before.rules:

      # BEGIN FORGE-NAT: <id>
      *nat
      :POSTROUTING ACCEPT [0:0]
      -A POSTROUTING -s 10.192.0.0/10 -o enp1s0 -j MASQUERADE
      COMMIT
      # END FORGE-NAT: <id>

  Observe parses the file looking for the markers. Apply replaces (or appends)
  the block, then runs `ufw reload`. Delete removes the block and reloads.

  ## Sandbox support

  When `config :mjolnir, :forge_ufw_before_rules_path` is set to a non-default
  path, `ufw reload` is skipped. The file is still read and written for full
  observation and apply testing.
  """

  @behaviour Mjolnir.Forge.Resource

  @default_before_rules "/etc/ufw/before.rules"

  def before_rules_path do
    Application.get_env(:mjolnir, :forge_ufw_before_rules_path, @default_before_rules)
  end

  @impl true
  def kind, do: "ufw_nat"

  @impl true
  def canonical(%{rules: rules}) when is_binary(rules), do: String.trim(rules)

  @impl true
  def observe_path(_id), do: :probe

  @impl true
  def parse_observed(bytes) when is_binary(bytes), do: %{rules: String.trim(bytes)}

  @impl true
  def probe(_host, id) do
    path = before_rules_path()

    case File.read(path) do
      {:ok, content} ->
        case extract_block(content, id) do
          nil -> :missing
          rules -> {:ok, %{rules: rules}}
        end

      {:error, :enoent} ->
        :missing

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def apply(_host, id, %{rules: rules}) when is_binary(rules) do
    path = before_rules_path()

    existing =
      case File.read(path) do
        {:ok, content} -> content
        {:error, :enoent} -> ""
      end

    new_content = upsert_block(existing, id, rules)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, new_content) do
      if ufw_active?() do
        case System.cmd("ufw", ["reload"], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, code} -> {:error, {:ufw_reload_failed, code, out}}
        end
      else
        :ok
      end
    end
  end

  @impl true
  def delete(_host, id) do
    path = before_rules_path()

    case File.read(path) do
      {:ok, content} ->
        new_content = remove_block(content, id)

        with :ok <- File.write(path, new_content) do
          if ufw_active?() do
            case System.cmd("ufw", ["reload"], stderr_to_stdout: true) do
              {_, 0} -> :ok
              {out, code} -> {:error, {:ufw_reload_failed, code, out}}
            end
          else
            :ok
          end
        end

      {:error, :enoent} ->
        :ok

      {:error, _} = err ->
        err
    end
  end

  # -- Block manipulation --

  defp begin_marker(id), do: "# BEGIN FORGE-NAT: #{id}"
  defp end_marker(id), do: "# END FORGE-NAT: #{id}"

  defp extract_block(content, id) do
    bm = begin_marker(id)
    em = end_marker(id)

    case Regex.run(
           ~r/#{Regex.escape(bm)}\n(.*?)#{Regex.escape(em)}/s,
           content
         ) do
      [_, rules] -> String.trim(rules)
      nil -> nil
    end
  end

  defp upsert_block(content, id, rules) do
    block = format_block(id, rules)

    if String.contains?(content, begin_marker(id)) do
      # Replace existing block
      bm = begin_marker(id)
      em = end_marker(id)

      Regex.replace(
        ~r/#{Regex.escape(bm)}\n.*?#{Regex.escape(em)}\n?/s,
        content,
        block
      )
    else
      # Append before the final newline (or at end)
      content = String.trim_trailing(content)

      if content == "" do
        block
      else
        content <> "\n" <> block
      end
    end
  end

  defp remove_block(content, id) do
    bm = begin_marker(id)
    em = end_marker(id)

    Regex.replace(
      ~r/#{Regex.escape(bm)}\n.*?#{Regex.escape(em)}\n?/s,
      content,
      ""
    )
  end

  defp format_block(id, rules) do
    """
    #{begin_marker(id)}
    #{String.trim(rules)}
    #{end_marker(id)}
    """
  end

  defp ufw_active?, do: before_rules_path() == @default_before_rules
end
