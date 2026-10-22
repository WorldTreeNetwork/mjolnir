defmodule Mjolnir.Admit do
  @moduledoc """
  Host-side admission evaluator for request-path VM thaws (add-buzz-local-client).

  v1 is a **shape check**, fail-closed: a thaw requires an attestation map
  with matching `vm_id` and a non-negative integer `epoch`. The portable
  protocol (envelope, attestation shape, verdict vocabulary, pure validators)
  lives in `identikey-protocol` crate `identikey-admit`. This module remains
  the v1 Elixir evaluator — no Rustler NIF this slice.

  Lifecycle epoch is **not** `StateStore`'s persist generation.
  """

  @type payload :: term()
  @type vm_state :: %{
          optional(:restart_policy) => atom(),
          optional(:secrets_mode) => atom(),
          optional(atom()) => term()
        }

  @spec dormancy_reason(vm_state()) :: :ok | {:error, atom()}
  def dormancy_reason(%{secrets_mode: :persistent}), do: {:error, :secrets_prevent_dormancy}
  def dormancy_reason(%{restart_policy: :never}), do: {:error, :never_prevents_dormancy}
  def dormancy_reason(_), do: :ok

  @doc """
  True when a payload may thaw or queue a dormant VM.

  Missing, non-map, or mismatched attestation is deny.
  """
  @spec thaw_allowed?(String.t(), payload()) :: boolean()
  def thaw_allowed?(vm_id, payload) when is_binary(vm_id) do
    case attestation(payload) do
      {:ok, att} -> valid_attestation?(vm_id, att)
      :error -> false
    end
  end

  def thaw_allowed?(_, _), do: false

  @doc """
  Portable verdict vocabulary (`identikey-admit`): `:deny` | `:deliver`.

  `:drop` and `:reply_here` are facade policy (running-body relay, cache),
  not this evaluator.
  """
  @spec verdict(String.t(), payload()) :: :deny | :deliver
  def verdict(vm_id, payload) do
    if thaw_allowed?(vm_id, payload), do: :deliver, else: :deny
  end

  @spec attestation(payload()) :: {:ok, map()} | :error
  def attestation(payload) when is_map(payload) do
    att = Map.get(payload, "attestation") || Map.get(payload, :attestation)

    if is_map(att), do: {:ok, att}, else: :error
  end

  def attestation(_), do: :error

  @spec valid_attestation?(String.t(), map()) :: boolean()
  def valid_attestation?(vm_id, att) when is_map(att) do
    att_vm = Map.get(att, "vm_id") || Map.get(att, :vm_id)
    epoch = Map.get(att, "epoch") || Map.get(att, :epoch)
    att_vm == vm_id and is_integer(epoch) and epoch >= 0
  end

  def valid_attestation?(_, _), do: false
end
