defmodule Mjolnir.Auth.EdgeKeys do
  @moduledoc """
  Stable edge identity and delegated, rotating operational keys.

  The trust pin is the identikey XID of the Ed25519 inception key: SHA-256
  of the tagged CBOR signing public key (tag 40022) whose content is
  `[2, raw 32-byte key]`. Inside a signed tuple those 32 bytes are a CBOR
  byte string. JSON and other text boundaries store base58 of the same
  bytes. A self-asserted document label is not the pin. Operational
  authority is an Ed25519 signature by that inception key over a canonical
  dCBOR tuple.

  Private material is kept in an atomic bundle under `:auth_dir` (default
  `/var/lib/mjolnir/auth`).  Loading the bundle never opens `stable.key`, so
  the stable private key can be removed from the host for ordinary sessions.
  """

  import Bitwise

  @delegation_domain "identikey-mjolnir/v1"
  @delegation_purpose "op-delegation"
  @supersession_purpose "op-supersede"
  @restore_purpose "auth-restore"
  @purposes ["edge-proof", "cap-mint"]
  @default_ttl 86_400
  @default_restore_age 300

  @type keypair :: %{ed25519_public: binary(), ed25519_secret: binary()}
  @type delegation :: %{
          op_public: binary(),
          kid: String.t(),
          edge_xid: binary(),
          purposes: [String.t()],
          nbf: non_neg_integer(),
          exp: non_neg_integer(),
          no_onward: true,
          signature: binary()
        }

  @doc "Generate an Ed25519 keypair without activating it."
  @spec generate_keypair() :: keypair()
  def generate_keypair do
    {public, secret} = :crypto.generate_key(:eddsa, :ed25519)
    %{ed25519_public: public, ed25519_secret: secret}
  end

  @doc "Generate an operational key and kid without changing persisted state."
  @spec generate_operational() :: %{keypair: keypair(), kid: String.t()}
  def generate_operational do
    keypair = generate_keypair()
    %{keypair: keypair, kid: operational_kid(keypair.ed25519_public)}
  end

  # tag(40022) || array(2) || unsigned(2) || bstr(32). BCR-2024-010 hashes this.
  @xid_cbor_prefix <<0xD9, 0x9C, 0x56, 0x82, 0x02, 0x58, 0x20>>
  @bundle_version 2

  @doc """
  The 32-byte XID of an Ed25519 inception public key.

  SHA-256 of the tagged CBOR signing-public-key, not of the raw key.
  """
  @spec edge_xid(binary() | keypair()) :: binary()
  def edge_xid(%{ed25519_public: public}), do: edge_xid(public)

  def edge_xid(<<_::binary-size(32)>> = inception_public) do
    :crypto.hash(:sha256, @xid_cbor_prefix <> inception_public)
  end

  @doc "Base58 text form of `edge_xid/1`."
  @spec edge_xid_text(binary() | keypair()) :: String.t()
  def edge_xid_text(key), do: Mjolnir.Base58.encode(edge_xid(key))

  @doc "A deterministic selector for an operational public key. Not authority."
  @spec operational_kid(binary()) :: String.t()
  def operational_kid(<<_::binary-size(32)>> = public) do
    public |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  @doc "Canonical dCBOR bytes covered by an operational delegation."
  @spec delegation_signing_bytes(map()) :: binary()
  def delegation_signing_bytes(delegation) do
    dcbor_array([
      {:text, @delegation_domain},
      {:text, @delegation_purpose},
      {:bytes, fetch!(delegation, :op_public)},
      {:text, fetch!(delegation, :kid)},
      {:bytes, fetch!(delegation, :edge_xid)},
      {:array, Enum.map(fetch!(delegation, :purposes), &{:text, &1})},
      {:uint, fetch!(delegation, :nbf)},
      {:uint, fetch!(delegation, :exp)},
      {:bool, fetch!(delegation, :no_onward)}
    ])
  end

  @doc "Sign an operational delegation with the stable identity."
  @spec delegate(keypair(), binary(), String.t(), keyword()) ::
          {:ok, delegation()} | {:error, term()}
  def delegate(stable, op_public, kid, opts \\ []) do
    now = Keyword.get(opts, :nbf, Keyword.get(opts, :now, System.system_time(:second)))
    exp = Keyword.get(opts, :exp, now + Keyword.get(opts, :ttl, @default_ttl))
    purposes = Keyword.get(opts, :purposes, @purposes)
    xid = Keyword.get(opts, :edge_xid, edge_xid(stable))

    delegation = %{
      op_public: op_public,
      kid: kid,
      edge_xid: xid,
      purposes: purposes,
      nbf: now,
      exp: exp,
      no_onward: Keyword.get(opts, :no_onward, true)
    }

    with :ok <- validate_keypair(stable),
         :ok <- validate_delegation_shape(delegation),
         true <- xid == edge_xid(stable.ed25519_public) || {:error, :wrong_edge_xid} do
      {:ok,
       Map.put(
         delegation,
         :signature,
         sign(stable.ed25519_secret, delegation_signing_bytes(delegation))
       )}
    else
      false -> {:error, :invalid_delegation}
      {:error, _} = error -> error
    end
  end

  @doc "Verify the pin, delegation signature, purpose set, and validity window."
  @spec verify_delegation(String.t() | nil, binary(), map(), keyword()) ::
          :ok | {:error, term()}
  def verify_delegation(pin, stable_public, delegation, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with :ok <- verify_pin(pin, stable_public),
         :ok <- validate_delegation_shape(delegation),
         :ok <- verify_delegation_signature(stable_public, delegation),
         true <- fetch!(delegation, :edge_xid) == pin || {:error, :wrong_edge_xid},
         true <-
           (fetch!(delegation, :nbf) <= now and now <= fetch!(delegation, :exp)) ||
             {:error, :delegation_outside_validity} do
      :ok
    else
      false -> {:error, :invalid_delegation}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :invalid_delegation}
  end

  @doc "Verify one delegated key against optional supersession evidence."
  @spec verify_chain(String.t() | nil, binary(), map(), keyword()) :: :ok | {:error, term()}
  def verify_chain(pin, stable_public, delegation, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    supersessions = Keyword.get(opts, :supersessions, [])
    known_delegations = Keyword.get(opts, :delegations, [delegation])

    with :ok <- verify_delegation(pin, stable_public, delegation, now: now),
         :ok <- unique_kids(known_delegations),
         :ok <- consistent_kid_binding(delegation, known_delegations),
         :ok <- verify_supersessions(stable_public, supersessions),
         :ok <- not_superseded(fetch!(delegation, :kid), supersessions, now) do
      :ok
    end
  end

  @doc "Canonical dCBOR bytes covered by the sole supersession record type."
  @spec supersession_signing_bytes(map()) :: binary()
  def supersession_signing_bytes(record) do
    dcbor_array([
      {:text, @delegation_domain},
      {:text, @supersession_purpose},
      {:text, fetch!(record, :kid)},
      {:uint, fetch!(record, :exp_now)},
      {:text, fetch!(record, :next_kid)}
    ])
  end

  @doc "Sign effective revocation of `kid`; `next_kid` is not a delegation."
  @spec supersede(keypair(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def supersede(stable, kid, exp_now, next_kid)
      when is_binary(kid) and kid != "" and is_integer(exp_now) and exp_now >= 0 and
             is_binary(next_kid) and next_kid != "" do
    record = %{kid: kid, exp_now: exp_now, next_kid: next_kid}

    with :ok <- validate_keypair(stable) do
      {:ok,
       Map.put(
         record,
         :signature,
         sign(stable.ed25519_secret, supersession_signing_bytes(record))
       )}
    end
  end

  def supersede(_, _, _, _), do: {:error, :invalid_supersession}

  @doc "Verify a supersession signature. Its effective time is not record expiry."
  @spec verify_supersession(binary(), map()) :: :ok | {:error, term()}
  def verify_supersession(<<_::binary-size(32)>> = stable_public, record) do
    with kid when is_binary(kid) and kid != "" <- fetch!(record, :kid),
         exp when is_integer(exp) and exp >= 0 <- fetch!(record, :exp_now),
         next when is_binary(next) and next != "" <- fetch!(record, :next_kid),
         signature when is_binary(signature) <- fetch!(record, :signature),
         true <- verify(stable_public, supersession_signing_bytes(record), signature) do
      :ok
    else
      _ -> {:error, :invalid_supersession}
    end
  rescue
    _ -> {:error, :invalid_supersession}
  end

  def verify_supersession(_, _), do: {:error, :invalid_supersession}

  @doc "Create the stable identity and first activated operational bundle."
  @spec provision(keyword()) :: {:ok, map()} | {:error, term()}
  def provision(opts \\ []) do
    stable = Keyword.get(opts, :stable_keypair, generate_keypair())
    generated = Keyword.get(opts, :operational, generate_operational())
    op_keypair = Map.fetch!(generated, :keypair)
    kid = Map.fetch!(generated, :kid)
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, dir} <- ensure_auth_dir(opts),
         :ok <- ensure_unprovisioned(dir),
         :ok <- validate_keypair(stable),
         :ok <- validate_keypair(op_keypair),
         {:ok, delegation} <-
           delegate(stable, op_keypair.ed25519_public, kid,
             now: now,
             exp: Keyword.get(opts, :exp, now + Keyword.get(opts, :ttl, @default_ttl))
           ),
         state = %{
           edge_xid: edge_xid(stable),
           stable_public: stable.ed25519_public,
           current_kid: kid,
           current_private: op_keypair.ed25519_secret,
           delegations: [delegation],
           supersessions: [],
           restore_ids: []
         },
         :ok <- validate_state(state, now),
         :ok <- write_identity(dir, stable, false),
         :ok <- maybe_write_stable(dir, stable, opts),
         :ok <- write_bundle(dir, state),
         :ok <- write_identity(dir, stable, true) do
      {:ok, state}
    end
  end

  @doc "Load the active bundle. The stable private key is never opened."
  @spec load(keyword()) :: {:ok, map()} | {:error, term()}
  def load(opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, dir} <- checked_auth_dir(opts),
         {:ok, bytes} <- read_private(Path.join(dir, "bundle.json")),
         {:ok, state} <- decode_bundle(bytes),
         :ok <- validate_state(state, now) do
      {:ok, state}
    else
      {:error, :enoent} -> {:error, :missing_operational_state}
      {:error, :legacy_edge_pin} = error -> error
      {:error, :unsafe_auth_path} = error -> error
      {:error, :bad_permissions} = error -> error
      _ -> {:error, :invalid_operational_state}
    end
  end

  @doc "Load state or create the first op key only for a never-established identity."
  @spec load_or_initialize(keyword()) :: {:ok, map()} | {:error, term()}
  def load_or_initialize(opts \\ []) do
    case load(opts) do
      {:ok, _} = loaded ->
        loaded

      {:error, :missing_operational_state} ->
        initialize_existing_identity(opts)

      error ->
        error
    end
  end

  @doc "Rotate to a newly delegated key while retaining unexpired old grants."
  @spec rotate(keyword()) :: {:ok, map()} | {:error, term()}
  def rotate(opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, dir} <- checked_auth_dir(opts),
         {:ok, state} <- load(Keyword.put(opts, :now, now)),
         {:ok, stable} <- stable_for_ceremony(dir, state, opts),
         generated = Keyword.get(opts, :operational, generate_operational()),
         op = Map.fetch!(generated, :keypair),
         kid = Map.fetch!(generated, :kid),
         true <-
           not Enum.any?(state.delegations, &(fetch!(&1, :kid) == kid)) ||
             {:error, :reused_kid},
         {:ok, delegation} <-
           delegate(stable, op.ed25519_public, kid,
             now: now,
             exp: Keyword.get(opts, :exp, now + Keyword.get(opts, :ttl, @default_ttl))
           ),
         {:ok, supersessions} <- maybe_supersede_current(state, stable, kid, now, opts),
         next = %{
           state
           | current_kid: kid,
             current_private: op.ed25519_secret,
             delegations:
               retain_delegations(state.delegations, state.supersessions, now) ++ [delegation],
             supersessions: supersessions
         },
         :ok <- validate_state(next, now),
         :ok <- write_bundle(dir, next) do
      {:ok, next}
    else
      false -> {:error, :rotation_failed}
      {:error, _} = error -> error
    end
  end

  @doc "Sign with the active op key; no stable private key is consulted."
  @spec sign_operational(map(), String.t(), binary(), keyword()) ::
          {:ok, %{kid: String.t(), signature: binary()}} | {:error, term()}
  def sign_operational(state, purpose, message, opts \\ [])

  def sign_operational(state, purpose, message, opts)
      when purpose in @purposes and is_binary(message) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with :ok <- validate_state(state, now),
         delegation when not is_nil(delegation) <- find_delegation(state, state.current_kid),
         true <- purpose in delegation.purposes || {:error, :wrong_purpose} do
      {:ok, %{kid: state.current_kid, signature: sign(state.current_private, message)}}
    else
      nil -> {:error, :missing_delegation}
      {:error, _} = error -> error
    end
  end

  def sign_operational(_, _, _, _), do: {:error, :wrong_purpose}

  @doc "Require a capability expiry not later than its op-key delegation."
  @spec verify_capability_window(map(), String.t(), non_neg_integer(), keyword()) ::
          :ok | {:error, term()}
  def verify_capability_window(state, kid, capability_exp, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with delegation when not is_nil(delegation) <- find_delegation(state, kid),
         :ok <-
           verify_chain(state.edge_xid, state.stable_public, delegation,
             now: now,
             supersessions: state.supersessions
           ),
         true <-
           (is_integer(capability_exp) and capability_exp <= delegation.exp) ||
             {:error, :capability_outlives_delegation} do
      :ok
    else
      nil -> {:error, :unknown_kid}
      {:error, _} = error -> error
    end
  end

  @doc "Build a fresh restore attestation over reconciled public state."
  @spec attest_restore(keypair(), map(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def attest_restore(stable, reconciled_state, observed_supersessions, opts \\ []) do
    issued_at =
      Keyword.get(opts, :issued_at, Keyword.get(opts, :now, System.system_time(:second)))

    restore_id = Keyword.get(opts, :restore_id, random_restore_id())

    with :ok <- validate_keypair(stable),
         true <- edge_xid(stable) == reconciled_state.edge_xid || {:error, :wrong_edge_xid},
         :ok <- verify_supersessions(stable.ed25519_public, observed_supersessions) do
      record = %{
        bundle_hash: public_bundle_hash(reconciled_state),
        restore_id: restore_id,
        observed_revocations_hash: revocations_hash(observed_supersessions),
        issued_at: issued_at
      }

      {:ok,
       Map.put(record, :signature, sign(stable.ed25519_secret, restore_signing_bytes(record)))}
    else
      false -> {:error, :invalid_restore}
      {:error, _} = error -> error
    end
  end

  @doc "Activate reconciled backup input only with fresh, matching authority."
  @spec activate_restore(map(), [map()], map(), keyword()) :: {:ok, map()} | {:error, term()}
  def activate_restore(reconciled_state, observed_supersessions, attestation, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    max_age = Keyword.get(opts, :max_restore_age, @default_restore_age)
    merged = merge_supersessions(reconciled_state.supersessions, observed_supersessions)
    next = %{reconciled_state | supersessions: merged}

    with {:ok, dir} <- ensure_auth_dir(opts),
         true <-
           Keyword.get(opts, :current_evidence, false) || {:error, :missing_current_evidence},
         :ok <- verify_supersessions(next.stable_public, observed_supersessions),
         true <-
           public_bundle_hash(next) == fetch!(attestation, :bundle_hash) ||
             {:error, :restore_bundle_mismatch},
         true <-
           revocations_hash(observed_supersessions) ==
             fetch!(attestation, :observed_revocations_hash) ||
             {:error, :restore_revocations_mismatch},
         issued when is_integer(issued) <- fetch!(attestation, :issued_at),
         true <-
           (issued <= now and issued >= now - max_age) || {:error, :stale_restore_attestation},
         restore_id when is_binary(restore_id) and restore_id != "" <-
           fetch!(attestation, :restore_id),
         true <- restore_id not in next.restore_ids || {:error, :replayed_restore_attestation},
         signature when is_binary(signature) <- fetch!(attestation, :signature),
         true <-
           verify(next.stable_public, restore_signing_bytes(attestation), signature) ||
             {:error, :invalid_restore_signature},
         activated = %{next | restore_ids: [restore_id | next.restore_ids]},
         :ok <- validate_state(activated, now),
         :ok <- write_bundle(dir, activated) do
      {:ok, activated}
    else
      false -> {:error, :invalid_restore}
      _ -> {:error, :invalid_restore}
    end
  end

  @doc "Hash of deterministic public authority state; private bytes are excluded."
  @spec public_bundle_hash(map()) :: binary()
  def public_bundle_hash(state) do
    delegation_items =
      state.delegations
      |> Enum.sort_by(&fetch!(&1, :kid))
      |> Enum.map(fn delegation ->
        {:array,
         [
           {:bytes, delegation_signing_bytes(delegation)},
           {:bytes, fetch!(delegation, :signature)}
         ]}
      end)

    supersession_items =
      state.supersessions
      |> Enum.sort_by(&{fetch!(&1, :kid), fetch!(&1, :exp_now), fetch!(&1, :next_kid)})
      |> Enum.map(fn record ->
        {:array,
         [
           {:bytes, supersession_signing_bytes(record)},
           {:bytes, fetch!(record, :signature)}
         ]}
      end)

    dcbor_array([
      {:text, @delegation_domain},
      {:text, "auth-bundle"},
      {:bytes, state.stable_public},
      {:bytes, state.edge_xid},
      {:array, delegation_items},
      {:array, supersession_items},
      {:text, state.current_kid}
    ])
    |> then(&:crypto.hash(:sha256, &1))
  end

  @doc "Return the configured path if it resolves outside `btrfs_root`."
  @spec safe_auth_dir(keyword()) :: {:ok, String.t()} | {:error, term()}
  def safe_auth_dir(opts \\ []) do
    auth = opts |> Keyword.get(:auth_dir, auth_dir()) |> canonical_path()
    btrfs = opts |> Keyword.get(:btrfs_root, btrfs_root()) |> canonical_path()

    if auth == btrfs or String.starts_with?(auth, btrfs <> "/") do
      {:error, :unsafe_auth_path}
    else
      {:ok, auth}
    end
  rescue
    _ -> {:error, :unsafe_auth_path}
  end

  @doc false
  def restore_signing_bytes(record) do
    dcbor_array([
      {:text, @delegation_domain},
      {:text, @restore_purpose},
      {:bytes, fetch!(record, :bundle_hash)},
      {:text, fetch!(record, :restore_id)},
      {:bytes, fetch!(record, :observed_revocations_hash)},
      {:uint, fetch!(record, :issued_at)}
    ])
  end

  defp verify_pin(nil, _), do: {:error, :missing_pin}

  defp verify_pin(pin, <<_::binary-size(32)>> = stable_public) when is_binary(pin) do
    if pin == edge_xid(stable_public), do: :ok, else: {:error, :pin_mismatch}
  end

  defp verify_pin(_, _), do: {:error, :invalid_identity_public}

  defp validate_delegation_shape(delegation) do
    with <<_::binary-size(32)>> <- fetch!(delegation, :op_public),
         kid when is_binary(kid) and kid != "" <- fetch!(delegation, :kid),
         <<_::binary-size(32)>> <- fetch!(delegation, :edge_xid),
         true <- fetch!(delegation, :purposes) == @purposes,
         nbf when is_integer(nbf) and nbf >= 0 <- fetch!(delegation, :nbf),
         exp when is_integer(exp) and exp >= nbf <- fetch!(delegation, :exp),
         true <- fetch!(delegation, :no_onward) do
      :ok
    else
      _ -> {:error, :invalid_delegation}
    end
  rescue
    _ -> {:error, :invalid_delegation}
  end

  defp verify_delegation_signature(stable_public, delegation) do
    case fetch!(delegation, :signature) do
      signature when is_binary(signature) ->
        if verify(stable_public, delegation_signing_bytes(delegation), signature),
          do: :ok,
          else: {:error, :invalid_delegation_signature}

      _ ->
        {:error, :invalid_delegation_signature}
    end
  rescue
    _ -> {:error, :invalid_delegation_signature}
  end

  defp validate_keypair(%{
         ed25519_public: <<_::binary-size(32)>> = public,
         ed25519_secret: <<_::binary-size(32)>> = secret
       }) do
    probe = "mjolnir-edge-keypair-check"
    if verify(public, probe, sign(secret, probe)), do: :ok, else: {:error, :keypair_mismatch}
  end

  defp validate_keypair(_), do: {:error, :invalid_keypair}

  defp validate_state(state, now) do
    with :ok <- verify_pin(state.edge_xid, state.stable_public),
         :ok <- unique_kids(state.delegations),
         :ok <- verify_all_delegations(state),
         :ok <- verify_supersessions(state.stable_public, state.supersessions),
         delegation when not is_nil(delegation) <- find_delegation(state, state.current_kid),
         true <-
           derive_public(state.current_private) == delegation.op_public ||
             {:error, :private_public_mismatch},
         :ok <-
           verify_chain(state.edge_xid, state.stable_public, delegation,
             now: now,
             supersessions: state.supersessions
           ) do
      :ok
    else
      nil -> {:error, :missing_current_delegation}
      false -> {:error, :invalid_operational_state}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :invalid_operational_state}
  end

  defp verify_all_delegations(state) do
    Enum.reduce_while(state.delegations, :ok, fn delegation, _ ->
      result =
        with :ok <- validate_delegation_shape(delegation),
             true <- delegation.edge_xid == state.edge_xid || {:error, :wrong_edge_xid},
             :ok <- verify_delegation_signature(state.stable_public, delegation) do
          :ok
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp unique_kids(delegations) do
    kids = Enum.map(delegations, &fetch!(&1, :kid))
    if length(kids) == MapSet.size(MapSet.new(kids)), do: :ok, else: {:error, :reused_kid}
  end

  defp consistent_kid_binding(delegation, known_delegations) do
    kid = fetch!(delegation, :kid)
    public = fetch!(delegation, :op_public)

    if Enum.all?(known_delegations, fn known ->
         fetch!(known, :kid) != kid or fetch!(known, :op_public) == public
       end) do
      :ok
    else
      {:error, :reused_kid}
    end
  end

  defp verify_supersessions(stable_public, records) when is_list(records) do
    Enum.reduce_while(records, :ok, fn record, _ ->
      case verify_supersession(stable_public, record) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_supersessions(_, _), do: {:error, :invalid_supersessions}

  defp not_superseded(kid, supersessions, now) do
    if Enum.any?(supersessions, &(fetch!(&1, :kid) == kid and fetch!(&1, :exp_now) <= now)) do
      {:error, :superseded}
    else
      :ok
    end
  end

  defp maybe_supersede_current(state, stable, next_kid, now, opts) do
    if Keyword.get(opts, :supersede, false) do
      with {:ok, record} <- supersede(stable, state.current_kid, now, next_kid) do
        {:ok, merge_supersessions(state.supersessions, [record])}
      end
    else
      {:ok, state.supersessions}
    end
  end

  defp retain_delegations(delegations, supersessions, now) do
    Enum.filter(delegations, fn delegation ->
      delegation.exp >= now and not_superseded(delegation.kid, supersessions, now) == :ok
    end)
  end

  defp merge_supersessions(existing, observed) do
    (existing ++ observed)
    |> Enum.reduce(%{}, fn record, acc ->
      key = {fetch!(record, :kid), fetch!(record, :exp_now), fetch!(record, :next_kid)}
      Map.put(acc, key, record)
    end)
    |> Map.values()
  end

  defp revocations_hash(records) do
    records
    |> Enum.sort_by(&{fetch!(&1, :kid), fetch!(&1, :exp_now), fetch!(&1, :next_kid)})
    |> Enum.map(fn record ->
      {:array,
       [{:bytes, supersession_signing_bytes(record)}, {:bytes, fetch!(record, :signature)}]}
    end)
    |> then(&dcbor_array([{:text, @delegation_domain}, {:text, "revocations"}, {:array, &1}]))
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp initialize_existing_identity(opts) do
    with {:ok, dir} <- checked_auth_dir(opts),
         {:ok, identity_bytes} <- read_private(Path.join(dir, "identity.json")),
         {:ok, identity} <- decode_identity(identity_bytes),
         true <- not identity.established || {:error, :missing_operational_state},
         {:ok, stable_bytes} <- read_private(Path.join(dir, "stable.key")),
         {:ok, stable} <- decode_keypair(stable_bytes),
         true <- edge_xid(stable) == identity.edge_xid || {:error, :pin_mismatch},
         generated = generate_operational(),
         now = Keyword.get(opts, :now, System.system_time(:second)),
         {:ok, delegation} <-
           delegate(stable, generated.keypair.ed25519_public, generated.kid,
             now: now,
             exp: Keyword.get(opts, :exp, now + Keyword.get(opts, :ttl, @default_ttl))
           ),
         state = %{
           edge_xid: identity.edge_xid,
           stable_public: identity.stable_public,
           current_kid: generated.kid,
           current_private: generated.keypair.ed25519_secret,
           delegations: [delegation],
           supersessions: [],
           restore_ids: []
         },
         :ok <- validate_state(state, now),
         :ok <- write_bundle(dir, state),
         :ok <- write_identity(dir, stable, true) do
      {:ok, state}
    else
      false -> {:error, :invalid_identity_state}
      {:error, _} = error -> error
      _ -> {:error, :invalid_identity_state}
    end
  end

  defp stable_for_ceremony(dir, state, opts) do
    case Keyword.fetch(opts, :stable_keypair) do
      {:ok, stable} ->
        if edge_xid(stable) == state.edge_xid, do: {:ok, stable}, else: {:error, :pin_mismatch}

      :error ->
        with {:ok, bytes} <- read_private(Path.join(dir, "stable.key")),
             {:ok, stable} <- decode_keypair(bytes),
             true <- edge_xid(stable) == state.edge_xid do
          {:ok, stable}
        else
          _ -> {:error, :stable_private_unavailable}
        end
    end
  rescue
    _ -> {:error, :stable_private_unavailable}
  end

  defp find_delegation(state, kid), do: Enum.find(state.delegations, &(fetch!(&1, :kid) == kid))

  defp derive_public(<<_::binary-size(32)>> = secret) do
    {public, _secret} = :crypto.generate_key(:eddsa, :ed25519, secret)
    public
  end

  defp derive_public(_), do: nil

  defp sign(secret, bytes), do: :crypto.sign(:eddsa, :none, bytes, [secret, :ed25519])

  defp verify(public, bytes, signature),
    do: :crypto.verify(:eddsa, :none, bytes, signature, [public, :ed25519])

  defp ensure_unprovisioned(dir) do
    if Enum.any?(
         ["identity.json", "bundle.json", "stable.key"],
         &File.exists?(Path.join(dir, &1))
       ),
       do: {:error, :already_provisioned},
       else: :ok
  end

  defp maybe_write_stable(dir, stable, opts) do
    if Keyword.get(opts, :persist_stable_private, true) do
      atomic_private_write(Path.join(dir, "stable.key"), encode_keypair(stable))
    else
      :ok
    end
  end

  defp write_identity(dir, stable, established) do
    body =
      Jason.encode!(%{
        "version" => @bundle_version,
        "edge_xid" => edge_xid_text(stable),
        "stable_public" => Base.encode64(stable.ed25519_public),
        "op_established" => established
      })

    atomic_private_write(Path.join(dir, "identity.json"), body)
  end

  defp write_bundle(dir, state),
    do: atomic_private_write(Path.join(dir, "bundle.json"), encode_bundle(state))

  defp encode_keypair(keypair) do
    Jason.encode!(%{
      "public" => Base.encode64(keypair.ed25519_public),
      "secret" => Base.encode64(keypair.ed25519_secret)
    })
  end

  defp decode_keypair(bytes) do
    with {:ok, map} <- Jason.decode(bytes),
         {:ok, public} <- decode64(map["public"]),
         {:ok, secret} <- decode64(map["secret"]),
         keypair = %{ed25519_public: public, ed25519_secret: secret},
         :ok <- validate_keypair(keypair) do
      {:ok, keypair}
    end
  end

  defp encode_bundle(state) do
    Jason.encode!(%{
      "version" => @bundle_version,
      "edge_xid" => Mjolnir.Base58.encode(state.edge_xid),
      "stable_public" => Base.encode64(state.stable_public),
      "current_kid" => state.current_kid,
      "current_private" => Base.encode64(state.current_private),
      "delegations" => Enum.map(state.delegations, &encode_delegation/1),
      "supersessions" => Enum.map(state.supersessions, &encode_supersession/1),
      "restore_ids" => state.restore_ids
    })
  end

  defp decode_bundle(bytes) do
    with {:ok, %{"version" => version} = map} <- Jason.decode(bytes),
         :ok <- reject_legacy_version(version),
         true <- version == @bundle_version,
         {:ok, edge_xid} <- Mjolnir.Base58.decode(map["edge_xid"], 32),
         {:ok, stable_public} <- decode64(map["stable_public"]),
         {:ok, current_private} <- decode64(map["current_private"]),
         {:ok, delegations} <- map_list(map["delegations"], &decode_delegation/1),
         {:ok, supersessions} <- map_list(map["supersessions"], &decode_supersession/1),
         true <- is_list(map["restore_ids"]) and Enum.all?(map["restore_ids"], &is_binary/1) do
      {:ok,
       %{
         edge_xid: edge_xid,
         stable_public: stable_public,
         current_kid: map["current_kid"],
         current_private: current_private,
         delegations: delegations,
         supersessions: supersessions,
         restore_ids: map["restore_ids"]
       }}
    else
      {:error, :legacy_edge_pin} = error -> error
      _ -> {:error, :invalid_bundle}
    end
  end

  defp encode_delegation(record) do
    %{
      "op_public" => Base.encode64(record.op_public),
      "kid" => record.kid,
      "edge_xid" => Mjolnir.Base58.encode(record.edge_xid),
      "purposes" => record.purposes,
      "nbf" => record.nbf,
      "exp" => record.exp,
      "no_onward" => record.no_onward,
      "signature" => Base.encode64(record.signature)
    }
  end

  defp decode_delegation(map) do
    with {:ok, op_public} <- decode64(map["op_public"]),
         {:ok, edge_xid} <- Mjolnir.Base58.decode(map["edge_xid"], 32),
         {:ok, signature} <- decode64(map["signature"]) do
      {:ok,
       %{
         op_public: op_public,
         kid: map["kid"],
         edge_xid: edge_xid,
         purposes: map["purposes"],
         nbf: map["nbf"],
         exp: map["exp"],
         no_onward: map["no_onward"],
         signature: signature
       }}
    end
  end

  defp encode_supersession(record) do
    %{
      "kid" => record.kid,
      "exp_now" => record.exp_now,
      "next_kid" => record.next_kid,
      "signature" => Base.encode64(record.signature)
    }
  end

  defp decode_supersession(map) do
    with {:ok, signature} <- decode64(map["signature"]) do
      {:ok,
       %{
         kid: map["kid"],
         exp_now: map["exp_now"],
         next_kid: map["next_kid"],
         signature: signature
       }}
    end
  end

  defp decode_identity(bytes) do
    with {:ok, %{"version" => version} = map} <- Jason.decode(bytes),
         :ok <- reject_legacy_version(version),
         true <- version == @bundle_version,
         {:ok, public} <- decode64(map["stable_public"]),
         {:ok, pin} <- Mjolnir.Base58.decode(map["edge_xid"], 32),
         true <- pin == edge_xid(public),
         true <- is_boolean(map["op_established"]) do
      {:ok, %{stable_public: public, edge_xid: pin, established: map["op_established"]}}
    else
      {:error, :legacy_edge_pin} = error -> error
      _ -> {:error, :invalid_identity_state}
    end
  end

  defp reject_legacy_version(1), do: {:error, :legacy_edge_pin}
  defp reject_legacy_version(_), do: :ok

  defp map_list(list, mapper) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case mapper.(item) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp map_list(_, _), do: {:error, :invalid_list}

  defp decode64(value) when is_binary(value), do: Base.decode64(value)
  defp decode64(_), do: :error

  defp checked_auth_dir(opts) do
    with {:ok, dir} <- safe_auth_dir(opts),
         :ok <- check_mode(dir, :directory, 0o700) do
      {:ok, dir}
    end
  end

  defp ensure_auth_dir(opts) do
    with {:ok, dir} <- safe_auth_dir(opts),
         :ok <- secure_mkdir(dir),
         {:ok, checked} <- checked_auth_dir(Keyword.put(opts, :auth_dir, dir)) do
      {:ok, checked}
    end
  end

  # `File.mkdir` and `File.write` create through the BEAM's process-wide umask.
  # `install -m` passes the restrictive mode to creation, before any secret
  # bytes exist. We then verify the mode again before every open.
  defp secure_mkdir(dir) do
    case File.lstat(dir) do
      {:ok, _} ->
        check_mode(dir, :directory, 0o700)

      {:error, :enoent} ->
        with install when is_binary(install) <- System.find_executable("install"),
             {_output, 0} <- System.cmd(install, ["-d", "-m", "700", dir], stderr_to_stdout: true) do
          check_mode(dir, :directory, 0o700)
        else
          _ -> {:error, :secure_create_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp atomic_private_write(path, bytes) do
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with install when is_binary(install) <- System.find_executable("install"),
         false <- File.exists?(tmp),
         {_output, 0} <-
           System.cmd(install, ["-m", "600", "/dev/null", tmp], stderr_to_stdout: true),
         :ok <- check_mode(tmp, :regular, 0o600),
         {:ok, io} <- File.open(tmp, [:write, :binary]),
         :ok <- IO.binwrite(io, bytes),
         :ok <- :file.sync(io),
         :ok <- File.close(io),
         :ok <- check_mode(tmp, :regular, 0o600),
         :ok <- File.rename(tmp, path),
         :ok <- check_mode(path, :regular, 0o600) do
      sync_directory(Path.dirname(path))
      :ok
    else
      _ ->
        _ = File.rm(tmp)
        {:error, :secure_write_failed}
    end
  end

  defp read_private(path) do
    with :ok <- check_mode(path, :regular, 0o600),
         {:ok, io} <- File.open(path, [:read, :binary]),
         :ok <- check_mode(path, :regular, 0o600),
         bytes <- IO.binread(io, :eof),
         :ok <- File.close(io) do
      {:ok, bytes}
    else
      {:error, :enoent} = error -> error
      _ -> {:error, :bad_permissions}
    end
  end

  defp check_mode(path, type, expected) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: ^type, mode: mode}} when band(mode, 0o777) == expected -> :ok
      {:ok, _} -> {:error, :bad_permissions}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_directory(dir) do
    case :file.open(String.to_charlist(dir), [:read, :raw]) do
      {:ok, io} ->
        _ = :file.sync(io)
        _ = :file.close(io)

      _ ->
        :ok
    end
  end

  defp canonical_path(path), do: resolve_path(Path.expand(path), MapSet.new())

  defp resolve_path(path, seen) do
    parts = Path.split(path)
    {root, rest} = List.pop_at(parts, 0)
    resolve_parts(root, rest, seen)
  end

  defp resolve_parts(current, [], _seen), do: current

  defp resolve_parts(current, [part | rest], seen) do
    candidate = Path.join(current, part)

    case File.lstat(candidate) do
      {:ok, %{type: :symlink}} ->
        if MapSet.member?(seen, candidate), do: raise(ArgumentError, "symlink loop")
        {:ok, target} = File.read_link(candidate)
        target = if Path.type(target) == :absolute, do: target, else: Path.expand(target, current)
        resolve_path(Path.join([target | rest]), MapSet.put(seen, candidate))

      {:ok, _} ->
        resolve_parts(candidate, rest, seen)

      {:error, :enoent} ->
        Path.join([candidate | rest])

      {:error, reason} ->
        raise File.Error, reason: reason, action: "resolve", path: candidate
    end
  end

  defp auth_dir, do: Application.get_env(:mjolnir, :auth_dir, "/var/lib/mjolnir/auth")
  defp btrfs_root, do: Application.get_env(:mjolnir, :btrfs_root, "/var/lib/mjolnir/btrfs")

  defp random_restore_id,
    do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp fetch!(map, key) when is_map(map),
    do:
      Map.get(map, key, Map.get(map, Atom.to_string(key))) || raise(KeyError, key: key, term: map)

  # Definite lengths and shortest integer encodings are deterministic dCBOR
  # for this schema (arrays, UTF-8 text, byte strings, uints, and booleans).
  defp dcbor_array(items),
    do: [cbor_head(4, length(items)) | Enum.map(items, &dcbor_item/1)] |> IO.iodata_to_binary()

  defp dcbor_item({:text, text}) when is_binary(text), do: [cbor_head(3, byte_size(text)), text]

  defp dcbor_item({:bytes, bytes}) when is_binary(bytes),
    do: [cbor_head(2, byte_size(bytes)), bytes]

  defp dcbor_item({:uint, number}) when is_integer(number) and number >= 0,
    do: cbor_head(0, number)

  defp dcbor_item({:array, items}) when is_list(items), do: dcbor_array(items)
  defp dcbor_item({:bool, false}), do: <<0xF4>>
  defp dcbor_item({:bool, true}), do: <<0xF5>>

  defp cbor_head(major, number) when number < 24, do: <<major::3, number::5>>
  defp cbor_head(major, number) when number < 0x100, do: <<major::3, 24::5, number::8>>
  defp cbor_head(major, number) when number < 0x1_0000, do: <<major::3, 25::5, number::16>>
  defp cbor_head(major, number) when number < 0x1_0000_0000, do: <<major::3, 26::5, number::32>>
  defp cbor_head(major, number), do: <<major::3, 27::5, number::64>>
end
