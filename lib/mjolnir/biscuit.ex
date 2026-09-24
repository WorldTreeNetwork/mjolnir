defmodule Mjolnir.Biscuit do
  @moduledoc """
  Host Biscuit mint/verify and protocol Blake3 (`mjolnir-axsb.1.3`).

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

  @spec mint(String.t(), String.t(), String.t()) :: binary()
  def mint(private_hex, resource, operation)
      when is_binary(private_hex) and is_binary(resource) and is_binary(operation) do
    %{"ok" => true, "biscuit_b64" => b64} =
      rpc(%{
        op: "mint",
        private_hex: private_hex,
        resource: resource,
        operation: operation
      })

    Base.decode64!(b64)
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

    case System.cmd(bin, [json], stderr_to_stdout: true) do
      {out, 0} ->
        Jason.decode!(out)

      {out, code} ->
        raise "mjolnir-biscuit failed (exit #{code}): #{out}"
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
