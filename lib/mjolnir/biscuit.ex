defmodule Mjolnir.Biscuit do
  @moduledoc """
  Host Biscuit mint/verify and protocol Blake3 (`mjolnir-axsb.1.3`,
  durable root `mjolnir-reki.1`).

  Talks to the `mjolnir-biscuit` binary (same shape as `mjolnir-b3`).
  No HTTP. Login profiles live in `add-biscuit-profiles`.
  """

  @empty_blake3 Base.decode16!(
                  "AF1349B9F5F9A1A6A0404DEA36DCC9499BCB25C9ADC112B7CC9A93CAE41F3262",
                  case: :upper
                )

  @doc "Official Blake3 empty-string digest."
  def empty_vector, do: @empty_blake3

  @spec blake3_hash(binary()) :: binary()
  def blake3_hash(data) when is_binary(data) do
    %{"ok" => true, "digest_hex" => hex} = rpc(%{op: "blake3", data_b64: Base.encode64(data)})
    Base.decode16!(hex, case: :lower)
  end

  @spec holder_fingerprint(binary()) :: binary()
  def holder_fingerprint(ed25519_pub) when byte_size(ed25519_pub) == 32 do
    %{"ok" => true, "digest_hex" => hex} =
      rpc(%{op: "holder_fp", public_hex: Base.encode16(ed25519_pub, case: :lower)})

    Base.decode16!(hex, case: :lower)
  end

  @spec secret_commit(binary(), binary()) :: binary()
  def secret_commit(salt, secret) when is_binary(salt) and is_binary(secret) do
    %{"ok" => true, "digest_hex" => hex} =
      rpc(%{
        op: "commit",
        salt_b64: Base.encode64(salt),
        secret_b64: Base.encode64(secret)
      })

    Base.decode16!(hex, case: :lower)
  end

  @spec keypair() :: %{private_hex: String.t(), public_hex: String.t()}
  def keypair do
    %{"ok" => true, "private_hex" => priv, "public_hex" => pub} = rpc(%{op: "keypair"})
    %{private_hex: priv, public_hex: pub}
  end

  @authority_cache {__MODULE__, :authority}

  @doc "Loads and caches the operator-provisioned mint root, publishing its verifier."
  @spec authority() :: %{private_hex: String.t(), public_hex: String.t()}
  def authority do
    :global.trans({@authority_cache, self()}, fn ->
      root =
        case :persistent_term.get(@authority_cache, nil) do
          nil ->
            root = load_authority!()
            check_public!(root.public_hex)
            :persistent_term.put(@authority_cache, root)
            root

          root ->
            check_public!(root.public_hex)
            root
        end

      Application.put_env(:mjolnir, :biscuit_public_hex, root.public_hex)
      root
    end)
  end

  @doc "Mints with the cached durable host authority."
  @spec mint_production(String.t(), String.t()) :: binary()
  def mint_production(resource, operation) do
    mint(authority().private_hex, resource, operation)
  end

  defp load_authority! do
    path = Application.get_env(:mjolnir, :biscuit_root_path, "/var/lib/mjolnir/biscuit-root")

    # Resolve every component, including symlinked parent directories. Check both
    # the operator's spelling and the resolved location against snapshot/escrow roots.
    forbidden = [
      Application.fetch_env!(:mjolnir, :btrfs_root),
      Application.get_env(:mjolnir, :secret_escrow_dir, "/var/lib/mjolnir/escrow"),
      "/var/lib/mjolnir/escrow"
    ]

    expanded = Path.expand(path)
    resolved = resolve_path!(expanded)

    for dir <- forbidden,
        candidate <- [expanded, resolved],
        boundary <- [Path.expand(dir), resolve_path!(Path.expand(dir))] do
      if candidate == boundary or String.starts_with?(candidate, boundary <> "/") do
        raise "Biscuit authority path is inside a forbidden directory"
      end
    end

    with {:ok, stat} <- File.stat(resolved),
         true <- stat.type == :regular and Bitwise.band(stat.mode, 0o7777) == 0o600,
         {:ok, body} <- File.read(resolved),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\n?\z/, body) do
      private_hex = String.trim_trailing(body, "\n")

      {public, _private} =
        :crypto.generate_key(:eddsa, :ed25519, Base.decode16!(private_hex, case: :lower))

      %{private_hex: private_hex, public_hex: Base.encode16(public, case: :lower)}
    else
      _ ->
        raise "Biscuit authority file must be readable, regular, mode 0600, and contain 64 lowercase hex characters"
    end
  end

  defp check_public!(public_hex) do
    case Application.get_env(:mjolnir, :biscuit_public_hex) do
      nil -> :ok
      ^public_hex -> :ok
      _ -> raise "Biscuit public key disagrees with the authority file"
    end
  end

  defp resolve_path!(path, remaining \\ 40)
  defp resolve_path!(_path, 0), do: raise("Biscuit authority path has too many symlinks")
  defp resolve_path!("/", _remaining), do: "/"

  defp resolve_path!(path, remaining) do
    parent = resolve_path!(Path.dirname(path), remaining)
    candidate = Path.join(parent, Path.basename(path))

    case File.read_link(candidate) do
      {:ok, target} -> resolve_path!(Path.expand(target, parent), remaining - 1)
      {:error, reason} when reason in [:einval, :enoent] -> candidate
      {:error, _} -> raise "Biscuit authority path is unreadable"
    end
  end

  @spec mint(String.t(), String.t(), String.t()) :: binary()
  def mint(private_hex, resource, operation)
      when is_binary(private_hex) and is_binary(resource) and is_binary(operation) do
    result =
      rpc(%{op: "mint", private_hex: private_hex, resource: resource, operation: operation})

    with %{"ok" => true, "biscuit_b64" => b64} when is_binary(b64) <- result,
         {:ok, biscuit} <- Base.decode64(b64) do
      biscuit
    else
      _ -> raise "mjolnir-biscuit returned an invalid mint response"
    end
  end

  @spec parse(binary(), String.t()) :: :ok | {:error, term()}
  def parse(biscuit, public_hex) when is_binary(biscuit) and is_binary(public_hex) do
    case rpc(%{
           op: "parse",
           public_hex: public_hex,
           biscuit_b64: Base.encode64(biscuit)
         }) do
      %{"ok" => true} -> :ok
      other -> {:error, other}
    end
  rescue
    e -> {:error, e}
  end

  @spec append_holder(binary(), String.t(), String.t()) :: binary()
  def append_holder(biscuit, public_hex, fp)
      when is_binary(biscuit) and is_binary(public_hex) and is_binary(fp) do
    %{"ok" => true, "biscuit_b64" => b64} =
      rpc(%{
        op: "append_holder",
        public_hex: public_hex,
        biscuit_b64: Base.encode64(biscuit),
        fp: fp
      })

    Base.decode64!(b64)
  end

  @doc "Appends one check-only hop using the holder fingerprint already on the token."
  @spec append_hop(binary(), String.t()) :: binary() | {:error, term()}
  def append_hop(biscuit, public_hex) when is_binary(biscuit) and is_binary(public_hex) do
    case rpc(%{
           op: "append_hop",
           public_hex: public_hex,
           biscuit_b64: Base.encode64(biscuit)
         }) do
      %{"ok" => true, "biscuit_b64" => b64} when is_binary(b64) -> Base.decode64!(b64)
      other -> {:error, other}
    end
  rescue
    e -> {:error, e}
  end

  @spec authorize(binary(), String.t(), String.t(), String.t(), String.t(), boolean()) ::
          :ok | {:error, term()}
  def authorize(biscuit, public_hex, fp, resource, operation, inject_holder) do
    case rpc(%{
           op: "authorize",
           public_hex: public_hex,
           biscuit_b64: Base.encode64(biscuit),
           fp: fp,
           resource: resource,
           operation: operation,
           inject_holder: inject_holder
         }) do
      %{"ok" => true} -> :ok
      other -> {:error, other}
    end
  rescue
    e -> {:error, e}
  end

  defp rpc(map) do
    bin = biscuit_bin!()
    json = Jason.encode!(map)

    # System.cmd has no stdin option. A bounded pipe closes the CLI's stdin
    # after exactly this JSON body; only its byte count and executable path are
    # argv entries. No private bytes go through a shell command or environment.
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: [
          "-c",
          "head -c \"$1\" | \"$2\"",
          "biscuit-stdin",
          Integer.to_string(byte_size(json)),
          bin
        ]
      ])

    Port.command(port, json)
    {out, code} = receive_cli(port, [])

    case {code, Jason.decode(out)} do
      {0, {:ok, result}} when is_map(result) -> result
      _ -> raise "mjolnir-biscuit failed (exit #{code})"
    end
  end

  defp receive_cli(port, chunks) do
    receive do
      {^port, {:data, data}} -> receive_cli(port, [data | chunks])
      {^port, {:exit_status, code}} -> {IO.iodata_to_binary(Enum.reverse(chunks)), code}
    after
      30_000 ->
        Port.close(port)
        raise "mjolnir-biscuit timed out"
    end
  end

  defp biscuit_bin! do
    bin =
      Application.get_env(:mjolnir, :biscuit_bin, "/opt/mjolnir/bin/mjolnir-biscuit")

    if is_binary(bin) and File.regular?(bin) do
      bin
    else
      raise ArgumentError,
            "Biscuit binary missing (#{inspect(bin)}). Build with: cargo build -p mjolnir-biscuit --bin mjolnir-biscuit"
    end
  end
end
