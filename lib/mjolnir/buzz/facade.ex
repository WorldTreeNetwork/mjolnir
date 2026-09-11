defmodule Mjolnir.Buzz.Facade do
  @moduledoc """
  Protocol facade: Nostr (later Matrix) → OTP mailbox → last hop Nostr.

  The named wake producer for Buzz. Running-body mentions stay on the relay;
  the host mailbox is not required for those bytes. Dormant bodies translate
  here, then `Mjolnir.Admit.thaw_allowed?/2`, then `VM.deliver_message/3`.

  This process is not an event log. State is a counter, not kinds.
  """

  use GenServer

  alias Mjolnir.{Admit, Buzz.Nostr, DormantRegistry, VM}

  defstruct ingested: 0

  @type ingest_ok :: %{
          required(:verdict) => :deny | :drop | :reply_here | :deliver,
          optional(:reason) => atom(),
          optional(:message_id) => String.t(),
          optional(:nostr) => map()
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Ingress a Nostr event (mention or emulation) for `opts[:vm_id]`.

  Later Matrix (or other) adapters translate into the same internal message
  and call `ingest_internal/2` — not a second thaw path.

  Options: `:vm_id` (required), `:epoch` (non-negative integer, default 0).
  """
  @spec ingest(term(), keyword()) :: {:ok, ingest_ok()} | {:error, :invalid_event}
  def ingest(event, opts \\ []) do
    with {:ok, nostr} <- Nostr.conform(event),
         {:ok, vm_id} <- fetch_vm_id(opts),
         {:ok, epoch} <- fetch_epoch(opts) do
      ingest_internal(Nostr.to_internal(nostr, vm_id, epoch), Keyword.put(opts, :vm_id, vm_id))
    end
  end

  @doc "Same thaw path as `ingest/2` after protocol translation."
  @spec ingest_internal(term(), keyword()) :: {:ok, ingest_ok()} | {:error, :invalid_event}
  def ingest_internal(internal, opts \\ [])

  def ingest_internal(internal, opts) when is_map(internal) do
    GenServer.call(__MODULE__, {:ingest_internal, internal, opts})
  end

  def ingest_internal(_, _), do: {:error, :invalid_event}

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:ingest_internal, internal, opts}, _from, state) do
    reply = do_ingest(internal, opts)
    {:reply, reply, %{state | ingested: state.ingested + 1}}
  end

  defp do_ingest(internal, opts) do
    case fetch_vm_id(opts) do
      {:error, :invalid_event} ->
        {:ok, %{verdict: :deny, reason: :invalid_target}}

      {:ok, vm_id} ->
        cond do
          running?(vm_id) ->
            {:ok, %{verdict: :drop, reason: :relay}}

          dormant?(vm_id) ->
            admit_and_deliver(vm_id, internal)

          true ->
            {:ok, %{verdict: :deny, reason: :not_found}}
        end
    end
  end

  defp admit_and_deliver(vm_id, internal) do
    case Admit.verdict(vm_id, internal) do
      :deny ->
        {:ok, %{verdict: :deny, reason: :admission_denied}}

      :deliver ->
        case VM.deliver_message(vm_id, Nostr.producer(), internal) do
          {:ok, result} ->
            nostr =
              case Nostr.last_hop(internal) do
                {:ok, event} -> event
                _ -> nil
              end

            {:ok,
             %{
               verdict: :deliver,
               message_id: result.message_id,
               nostr: nostr
             }}

          {:error, :admission_denied} ->
            {:ok, %{verdict: :deny, reason: :admission_denied}}

          {:error, reason} ->
            {:ok, %{verdict: :deny, reason: reason}}
        end
    end
  end

  defp running?(vm_id), do: Registry.lookup(Mjolnir.VMRegistry, vm_id) != []

  defp dormant?(vm_id), do: match?({:ok, _}, DormantRegistry.lookup(vm_id))

  defp fetch_vm_id(opts) do
    case Keyword.get(opts, :vm_id) do
      vm_id when is_binary(vm_id) and vm_id != "" -> {:ok, vm_id}
      _ -> {:error, :invalid_event}
    end
  end

  defp fetch_epoch(opts) do
    case Keyword.get(opts, :epoch, 0) do
      epoch when is_integer(epoch) and epoch >= 0 -> {:ok, epoch}
      _ -> {:error, :invalid_event}
    end
  end
end
