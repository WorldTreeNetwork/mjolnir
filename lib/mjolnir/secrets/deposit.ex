defmodule Mjolnir.Secrets.Deposit do
  @moduledoc """
  Deposits an immutable opaque secret and mints its holder-checked redeem token.

  An existing id, including an incomplete deposit, is always refused. Only the
  attempt that exclusively creates the id directory may publish or clean it up.
  """

  alias Mjolnir.{Biscuit, SecretStore}

  @spec deposit(String.t(), binary(), binary()) :: {:ok, binary()} | {:error, atom()}
  def deposit(secret_id, secret, owner_public) do
    with :ok <- validate(secret_id, secret, owner_public),
         parent = Path.join([SecretStore.root(), "_opaque", "secrets"]),
         :ok <- File.mkdir_p(parent),
         dir = Path.join(parent, secret_id),
         :ok <- File.mkdir(dir) do
      case publish(secret_id, secret, owner_public) do
        {:ok, token} -> {:ok, token}
        {:error, _} -> rollback(dir)
      end
    else
      {:error, :eexist} -> {:error, :already_exists}
      {:error, :invalid_deposit} -> {:error, :invalid_deposit}
      _ -> {:error, :reservation_failed}
    end
  end

  defp validate(id, secret, owner)
       when is_binary(id) and id != "" and is_binary(secret) and byte_size(secret) > 0 and
              is_binary(owner) and byte_size(owner) == 32 do
    if String.valid?(id) and id != "." and not String.contains?(id, ["/", "\\", "\0", ".."]) do
      :ok
    else
      {:error, :invalid_deposit}
    end
  end

  defp validate(_, _, _), do: {:error, :invalid_deposit}

  defp publish(id, secret, owner) do
    with :ok <- checkpoint(:reserved),
         salt = :crypto.strong_rand_bytes(32),
         meta =
           Jason.encode!(%{
             salt_b64: Base.encode64(salt),
             commitment_hex: Base.encode16(Biscuit.secret_commit(salt, secret), case: :lower)
           }),
         fp = Base.encode16(Biscuit.holder_fingerprint(owner), case: :lower),
         :ok <- put(id, "value", secret),
         :ok <- put(id, "meta", meta),
         :ok <- put(id, "owner", fp),
         :ok <- checkpoint(:mint),
         token when is_binary(token) <- Biscuit.mint_production(id, "redeem"),
         public_hex = Application.fetch_env!(:mjolnir, :biscuit_public_hex),
         :ok <- checkpoint(:append),
         held when is_binary(held) <- Biscuit.append_holder(token, public_hex, fp) do
      {:ok, held}
    else
      _ -> {:error, :publication_failed}
    end
  rescue
    _ -> {:error, :publication_failed}
  catch
    _, _ -> {:error, :publication_failed}
  end

  defp put(id, key, bytes) do
    with :ok <- checkpoint({:write, key}) do
      SecretStore.put_opaque("secrets", id, key, bytes)
    end
  end

  defp rollback(dir) do
    with :ok <- checkpoint(:cleanup),
         {:ok, _} <- File.rm_rf(dir) do
      {:error, :publication_failed}
    else
      _ -> {:error, :cleanup_failed}
    end
  rescue
    _ -> {:error, :cleanup_failed}
  catch
    _, _ -> {:error, :cleanup_failed}
  end

  # Unset in normal operation. Only this module reads the fault-injection hook;
  # it receives a stage, never the secret, salt, owner key, or token.
  defp checkpoint(stage) do
    case Application.get_env(:mjolnir, :deposit_test_hook) do
      nil -> :ok
      hook when is_function(hook, 1) -> hook.(stage)
    end
  end
end
