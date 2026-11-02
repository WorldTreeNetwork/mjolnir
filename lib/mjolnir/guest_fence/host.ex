defmodule Mjolnir.GuestFence.Host do
  @moduledoc """
  Host authority behind HostFence, independent of a channel transport.

  Start with `directory:` on host storage and policy-owned `effect_contracts:`.
  `connect/2` is a TRUSTED transport adapter entry point: its instance must come
  from authenticated host metadata, never guest input. The returned opaque
  channel is bound to the calling transport process; process death or explicit
  disconnect removes its lease. Identity returns only journal and instance.

  Classifications and grants are opaque host-issued ids/maps. Commit accepts
  `%{op: :adopt, grant: grant, classification: id}`, or Lease/Admit with those
  bindings plus `scope`, `key`, `digest`, and `effect_contract`. Reconcile takes
  only `op`, `scope`, `key`, and optionally a recorded `grant`; it requires the
  separate policy callback `reconcile_authorizer: fn instance, scope, key -> ... end`.

  A callback is a guest journal write, never permission to send an effect. It
  executes in the calling process AFTER acceptance is synced. Its result is
  discarded; failures leave acceptance recorded. The host stays responsive to
  transfer, revocation and disconnect while the callback is blocked. No callback
  or callback result is persisted or returned as reusable mutation authority.
  """
  use GenServer
  alias Mjolnir.GuestFence.Store

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Trusted authenticated transport entry point; :designated uses host metadata."
  def connect(host, instance \\ :designated), do: call(host, {:connect, instance})
  def disconnect(host, channel), do: call(host, {:disconnect, channel})
  def identity(host, channel), do: call(host, {:identity, channel})
  def classify(host, channel, receipts), do: call(host, {:classify, channel, receipts})

  def begin_adoption(host, channel, classification),
    do: call(host, {:begin, channel, classification})

  def confirm(host, channel, grant), do: call(host, {:confirm, channel, grant})

  def commit(host, channel, mutation, guest_write \\ fn _ -> :ok end)
      when is_function(guest_write, 1) do
    case call(host, {:commit, channel, mutation}) do
      {:write, receipt} ->
        try do
          case guest_write.(receipt) do
            {:error, _} -> {:error, {:guest_write_failed, receipt}}
            _ -> {:ok, receipt}
          end
        rescue
          _ -> {:error, {:guest_write_failed, receipt}}
        catch
          _, _ -> {:error, {:guest_write_failed, receipt}}
        end

      other ->
        other
    end
  end

  @doc "Host control operation. Generates a new designated instance and revokes old grants."
  def transfer(host, channel, classification),
    do: call(host, {:transfer, channel, classification})

  @doc "Host lifecycle operation, never exposed to unauthenticated guest requests."
  def restore(host), do: call(host, :restore)
  def clone(host), do: restore(host)
  def revoke(host), do: call(host, :revoke)
  defp call(host, message), do: GenServer.call(host, message, :infinity)
  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  @impl true
  def init(opts) do
    directory = opts |> Keyword.fetch!(:directory) |> Path.expand()
    lock = {__MODULE__, directory}

    if :global.register_name(lock, self()) == :yes do
      case Store.open(directory) do
        {:ok, store, saved} ->
          data =
            saved ||
              %{
                version: 1,
                journal: id(),
                instance: id(),
                generation: 0,
                revision: 0,
                admissions: %{},
                grants: %{},
                current: nil,
                classifications: %{}
              }

          if valid_state?(data) do
            case Store.append(store, data) do
              :ok ->
                {:ok,
                 %{
                   store: store,
                   data: data,
                   channels: %{},
                   contracts: MapSet.new(Keyword.get(opts, :effect_contracts, [])),
                   reconciler: Keyword.get(opts, :reconcile_authorizer, fn _, _, _ -> false end)
                 }}

              error ->
                Store.close(store)
                {:stop, error}
            end
          else
            Store.close(store)
            {:stop, :uncertain_store}
          end

        error ->
          {:stop, error}
      end
    else
      {:stop, :store_already_open}
    end
  end

  defp valid_state?(%{
         version: 1,
         journal: j,
         instance: i,
         generation: g,
         revision: r,
         admissions: a,
         grants: grants,
         current: _,
         classifications: c
       }),
       do:
         is_binary(j) and is_binary(i) and is_integer(g) and g >= 0 and
           is_integer(r) and r >= 0 and is_map(a) and is_map(grants) and is_map(c)

  defp valid_state?(_), do: false

  @impl true
  def handle_call({:connect, instance}, {pid, _}, state) do
    instance = if instance == :designated, do: state.data.instance, else: instance

    if is_binary(instance) do
      token = id()
      channel = %{instance: instance, pid: pid, monitor: Process.monitor(pid), lease: nil}
      {:reply, {:ok, token}, put_in(state.channels[token], channel)}
    else
      {:reply, {:error, :invalid_instance}, state}
    end
  end

  def handle_call(:restore, _, state), do: rotate(state, true)

  def handle_call(:revoke, _, state) do
    data = revoke_grants(state.data)
    persist(state, data, :ok, true)
  end

  def handle_call(request, {pid, _}, state) do
    channel = elem(request, 1)

    case Map.get(state.channels, channel) do
      %{pid: ^pid, instance: instance} -> dispatch(request, instance, state)
      _ -> {:reply, {:error, :unauthenticated}, state}
    end
  end

  defp dispatch({:identity, _}, instance, state),
    do: {:reply, {:ok, %{journal: state.data.journal, instance: instance}}, state}

  defp dispatch({:disconnect, channel}, _, state) do
    {entry, channels} = Map.pop(state.channels, channel)
    Process.demonitor(entry.monitor, [:flush])
    {:reply, :ok, %{state | channels: channels}}
  end

  defp dispatch({:classify, _, receipts}, instance, state) do
    case coverage(state.data, receipts) do
      :ok ->
        classification = id()
        row = %{journal: state.data.journal, instance: instance, revision: state.data.revision}
        data = put_in(state.data, [:classifications, classification], row)
        persist(state, data, {:ok, classification})

      error ->
        {:reply, error, state}
    end
  end

  defp dispatch({:begin, _, classification}, instance, state) do
    with :ok <- classified(state.data, instance, classification),
         true <- instance == state.data.instance do
      case state.data.current && state.data.grants[state.data.current] do
        %{state: status} = grant when status in [:pending, :confirmed] ->
          {:reply, {:ok, grant}, state}

        _ ->
          generation = state.data.generation + 1

          grant = %{
            id: id(),
            journal: state.data.journal,
            instance: instance,
            generation: generation,
            state: :pending,
            adopted: false
          }

          data = %{
            state.data
            | generation: generation,
              current: grant.id,
              grants: Map.put(state.data.grants, grant.id, grant)
          }

          persist(state, data, {:ok, grant})
      end
    else
      false -> {:reply, {:error, :not_designated}, state}
      error -> {:reply, error, state}
    end
  end

  defp dispatch({:confirm, _, supplied}, instance, state) do
    with {:ok, grant} <- current_grant(state.data, instance, supplied),
         true <- grant.adopted do
      confirmed = %{grant | state: :confirmed}
      persist(state, put_in(state.data, [:grants, grant.id], confirmed), {:ok, confirmed})
    else
      false -> {:reply, {:error, :not_adopted}, state}
      error -> {:reply, error, state}
    end
  end

  defp dispatch({:transfer, _, classification}, instance, state) do
    with :ok <- classified(state.data, instance, classification),
         true <- instance == state.data.instance do
      rotate(state, false)
    else
      false -> {:reply, {:error, :not_designated}, state}
      error -> {:reply, error, state}
    end
  end

  defp dispatch({:commit, channel, mutation}, instance, state) when is_map(mutation) do
    case mutation do
      %{op: :reconcile} ->
        reconcile(state, instance, mutation)

      %{op: op, grant: supplied, classification: classification}
      when op in [:adopt, :lease, :admit] ->
        with :ok <- classified(state.data, instance, classification),
             {:ok, grant} <- current_grant(state.data, instance, supplied) do
          mutate(state, channel, grant, classification, mutation)
        else
          error -> {:reply, error, state}
        end

      _ ->
        {:reply, {:error, :invalid_mutation}, state}
    end
  end

  defp dispatch(_, _, state), do: {:reply, {:error, :invalid_request}, state}

  defp mutate(state, _, grant, _, %{op: :adopt} = mutation) do
    if exact_keys?(mutation, [:op, :grant, :classification]) do
      adopted = %{grant | adopted: true}
      persist(state, put_in(state.data, [:grants, grant.id], adopted), {:ok, adopted})
    else
      {:reply, {:error, :invalid_mutation}, state}
    end
  end

  defp mutate(state, channel, grant, classification, mutation) do
    with true <- grant.state == :confirmed,
         :ok <- valid_effect(state, mutation) do
      case mutation.op do
        :lease ->
          lease = Map.take(mutation, [:scope, :key, :digest, :effect_contract])
          {:reply, :ok, put_in(state.channels[channel].lease, {grant.id, lease})}

        :admit ->
          admit(state, channel, grant, classification, mutation)
      end
    else
      false -> {:reply, {:error, :unconfirmed}, state}
      error -> {:reply, error, state}
    end
  end

  defp valid_effect(state, mutation) do
    if exact_keys?(mutation, [
         :op,
         :grant,
         :classification,
         :scope,
         :key,
         :digest,
         :effect_contract
       ]) and
         Enum.all?(
           [:scope, :key, :digest, :effect_contract],
           &(is_binary(mutation[&1]) and mutation[&1] != "")
         ) do
      if MapSet.member?(state.contracts, mutation.effect_contract),
        do: :ok,
        else: {:error, :unknown_effect_contract}
    else
      {:error, :invalid_mutation}
    end
  end

  defp admit(state, channel, grant, classification, mutation) do
    key = {mutation.scope, mutation.key}

    case Map.get(state.data.admissions, key) do
      %{receipt: %{digest: digest}, effect_contract: contract} = record ->
        if digest == mutation.digest and contract == mutation.effect_contract do
          {:reply, {:ok, record.receipt}, state}
        else
          {:reply, {:error, :digest_conflict}, state}
        end

      nil ->
        receipt = %{
          scope: mutation.scope,
          key: mutation.key,
          digest: mutation.digest,
          claim_state: :admitted,
          generation: grant.generation
        }

        record = %{
          receipt: receipt,
          grant_id: grant.id,
          instance: grant.instance,
          journal: grant.journal,
          effect_contract: mutation.effect_contract
        }

        revision = state.data.revision + 1

        data = %{
          state.data
          | admissions: Map.put(state.data.admissions, key, record),
            revision: revision
        }

        data = put_in(data.classifications[classification].revision, revision)
        state = put_in(state.channels[channel].lease, nil)
        persist(state, data, {:write, receipt})
    end
  end

  defp reconcile(state, instance, mutation) do
    allowed = [:op, :scope, :key] ++ if(Map.has_key?(mutation, :grant), do: [:grant], else: [])

    with true <- exact_keys?(mutation, allowed),
         true <- is_binary(mutation.scope) and is_binary(mutation.key),
         true <- state.reconciler.(instance, mutation.scope, mutation.key) == true,
         :ok <- recorded_grant(state.data, Map.get(mutation, :grant)),
         %{receipt: receipt} <- state.data.admissions[{mutation.scope, mutation.key}] do
      {:reply, {:ok, receipt}, state}
    else
      nil -> {:reply, {:error, :unknown_key}, state}
      false -> {:reply, {:error, :unauthorized_reconcile}, state}
      error -> {:reply, error, state}
    end
  end

  defp recorded_grant(_, nil), do: :ok

  defp recorded_grant(data, supplied) do
    case find_grant(data, supplied) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_grant}
    end
  end

  # Mutable lifecycle fields are observations; immutable bindings must all match.
  defp find_grant(data, %{id: id} = supplied) do
    case Map.get(data.grants, id) do
      nil ->
        {:error, :invalid_grant}

      grant ->
        fields = [:id, :journal, :instance, :generation]

        if Map.take(supplied, fields) == Map.take(grant, fields),
          do: {:ok, grant},
          else: {:error, :invalid_grant}
    end
  end

  defp find_grant(_, _), do: {:error, :invalid_grant}

  defp current_grant(data, instance, supplied) do
    with {:ok, grant} <- find_grant(data, supplied),
         true <-
           grant.id == data.current and grant.instance == instance and
             instance == data.instance and grant.generation == data.generation and
             grant.generation > 0 and grant.state in [:pending, :confirmed] do
      {:ok, grant}
    else
      false -> {:error, :not_owner}
      error -> error
    end
  end

  defp classified(data, instance, classification) do
    case Map.get(data.classifications, classification) do
      %{journal: journal, instance: ^instance, revision: revision}
      when journal == data.journal and revision == data.revision ->
        :ok

      nil ->
        {:error, :unknown_classification}

      %{instance: other} when other != instance ->
        {:error, :foreign_classification}

      _ ->
        {:error, :stale_classification}
    end
  end

  defp coverage(data, receipts) when is_list(receipts) do
    Enum.reduce_while(receipts, {:ok, MapSet.new()}, fn receipt, {:ok, seen} ->
      case receipt do
        %{scope: scope, key: key, digest: digest, claim_state: claim, generation: generation} ->
          k = {scope, key}

          case Map.get(data.admissions, k) do
            nil ->
              {:halt, {:error, :unknown_receipt}}

            %{receipt: retained} ->
              cond do
                MapSet.member?(seen, k) ->
                  {:halt, {:error, :duplicate_receipt}}

                generation == 0 ->
                  {:halt, {:error, :legacy_receipt}}

                generation != retained.generation ->
                  {:halt, {:error, :generation_mismatch}}

                digest != retained.digest ->
                  {:halt, {:error, :digest_mismatch}}

                claim != :admitted or retained.claim_state != :admitted ->
                  {:halt, {:error, :incomplete_classification}}

                not exact_keys?(receipt, [:scope, :key, :digest, :claim_state, :generation]) ->
                  {:halt, {:error, :invalid_receipt}}

                true ->
                  {:cont, {:ok, MapSet.put(seen, k)}}
              end
          end

        _ ->
          {:halt, {:error, :invalid_receipt}}
      end
    end)
    |> case do
      {:ok, seen} ->
        if MapSet.size(seen) == map_size(data.admissions),
          do: :ok,
          else: {:error, :incomplete_classification}

      error ->
        error
    end
  end

  defp coverage(_, _), do: {:error, :invalid_receipts}

  defp exact_keys?(map, keys), do: MapSet.new(Map.keys(map)) == MapSet.new(keys)

  defp revoke_grants(data) do
    grants = Map.new(data.grants, fn {id, grant} -> {id, %{grant | state: :revoked}} end)
    %{data | grants: grants, current: nil}
  end

  defp rotate(state, advance) do
    data = revoke_grants(state.data)
    # Transfer reserves no grant; begin allocates its generation. Restore must
    # advance immediately even if the guest never begins adoption.
    data = %{
      data
      | instance: id(),
        generation: data.generation + if(advance, do: 1, else: 0),
        classifications: %{}
    }

    persist(state, data, {:ok, %{journal: data.journal, instance: data.instance}}, true)
  end

  defp persist(state, data, reply, drop_leases \\ false) do
    case Store.append(state.store, data) do
      :ok ->
        channels =
          if drop_leases,
            do: Map.new(state.channels, fn {id, channel} -> {id, %{channel | lease: nil}} end),
            else: state.channels

        {:reply, reply, %{state | data: data, channels: channels}}

      error ->
        # A failed sync may have written a frame. Stop rather than allow any
        # further mutation based on an uncertain in-memory state.
        {:stop, {:store_unavailable, error}, {:error, :store_unavailable}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    channels = Map.reject(state.channels, fn {_, channel} -> channel.monitor == monitor end)
    {:noreply, %{state | channels: channels}}
  end

  @impl true
  def terminate(_, state), do: Store.close(state.store)
end
