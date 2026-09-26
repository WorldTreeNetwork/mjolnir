defmodule Mjolnir.Auth.LoginProfile do
  @moduledoc """
  Holder-bound and explicit-bearer login profiles over `Mjolnir.Biscuit`.

  This module is an adapter, not another capability runtime. The canonical
  profile is committed by the authority `right/2` minted by
  `Mjolnir.Biscuit`; holder tokens then receive the runtime's unremovable
  holder check. Authorization returns a decision for exactly one request.

  A nonce store is injected at authorization time. It may be a three-arity
  function or a module exporting `consume/3`; `consume(nonce, now, proof_exp)`
  must atomically accept an outstanding nonce once, enforce its own expiry,
  and fail closed when the nonce is unknown.
  """

  alias Mjolnir.Biscuit

  @magic "MJLP1"
  @profile_version "mjolnir-login-profile/v1"
  @proof_version "mjolnir-login/v1"
  @signing_domain "identikey-mjolnir/v1"
  @signing_purpose "login-proof"

  @type right :: {String.t(), String.t()}
  @type decision :: {:allow, map()} | {:deny, atom()}

  @doc """
  Mints a login capability. Holder mode is the default.

  Claims require `:subject_xid`, `:edge_xid`, `:rights`, and `:exp`.
  Holder claims additionally require the 32-byte `:session_public`.

  Bearer mode must be explicitly selected with `mode: :bearer` and requires
  `holder_policy: %{rights: [...], exp: unix_seconds}`. Its rights must be a
  proper subset and its expiry strictly earlier than that holder policy.
  """
  @spec mint(String.t(), map(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def mint(root_private_hex, claims, opts \\ [])

  def mint(root_private_hex, claims, opts)
      when is_binary(root_private_hex) and is_map(claims) and is_list(opts) do
    mode = Keyword.get(opts, :mode, :holder)
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, profile} <- normalize_profile(claims, mode, now, opts),
         profile_bytes <- encode_profile(profile),
         resource <- authority_resource(profile_bytes),
         operation <- authority_operation(mode),
         biscuit <- Biscuit.mint(root_private_hex, resource, operation),
         {:ok, biscuit} <- bind_holder(biscuit, profile, root_private_hex) do
      {:ok, pack(profile_bytes, biscuit)}
    end
  rescue
    _ -> {:error, :mint_failed}
  end

  def mint(_, _, _), do: {:error, :invalid_claims}

  @doc "Mints the default holder-bound profile."
  @spec mint_holder(String.t(), map(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def mint_holder(root_private_hex, claims, opts \\ []) do
    mint(root_private_hex, claims, Keyword.put(opts, :mode, :holder))
  end

  @doc "Mints an explicitly requested, narrower bearer profile."
  @spec mint_bearer(String.t(), map(), map(), keyword()) ::
          {:ok, binary()} | {:error, atom()}
  def mint_bearer(root_private_hex, claims, holder_policy, opts \\ []) do
    opts = opts |> Keyword.put(:mode, :bearer) |> Keyword.put(:holder_policy, holder_policy)
    mint(root_private_hex, claims, opts)
  end

  @doc """
  Authorizes one request and returns `{:allow, audit_fields}` or
  `{:deny, reason}`. A denial is terminal; this function has no JWT or
  localhost fallback.

  The request carries `:edge_xid`, `:operation`, and `:resource`. Holder
  requests also carry uppercase `:method`, exact `:request_target`, exact
  `:body`, and `:proof` (`:nonce`, `:exp`, `:signature`). Options require the
  operational root as `:root_public_hex`; holder mode additionally requires
  `:nonce_store`.
  """
  @spec authorize(binary(), map(), map(), keyword()) :: decision()
  def authorize(token, request, trusted, opts)
      when is_binary(token) and is_map(request) and is_map(trusted) and is_list(opts) do
    root_public_hex = Map.get(trusted, :root_public_hex) || Map.get(trusted, "root_public_hex")
    expected_edge = Map.get(trusted, :edge_xid) || Map.get(trusted, "edge_xid")
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, profile_bytes, biscuit, profile} <- unpack(token),
         :ok <- trusted_root(root_public_hex),
         :ok <- current(profile, now),
         :ok <- expected_audience(profile, expected_edge),
         :ok <- permitted(profile, request),
         {:ok, inject_holder, nonce} <- holder_evidence(profile, token, request, now),
         :ok <-
           runtime_authorize(
             biscuit,
             root_public_hex,
             profile,
             profile_bytes,
             inject_holder
           ),
         :ok <- consume_nonce(profile, nonce, request, now, opts) do
      {:allow,
       %{
         subject_xid: profile.subject_xid,
         edge_xid: profile.edge_xid,
         login_mode: profile.mode,
         exp: profile.exp
       }}
    else
      {:error, reason} when is_atom(reason) -> {:deny, reason}
    end
  rescue
    _ -> {:deny, :invalid_token}
  end

  def authorize(_, _, _, _), do: {:deny, :invalid_request}

  @doc "Builds a request proof signed by the session key."
  @spec sign_proof(binary(), map(), String.t(), binary(), integer(), binary() | map()) :: map()
  def sign_proof(token, request, edge_xid, nonce, exp, session_key)
      when is_binary(token) and is_map(request) and is_binary(edge_xid) and
             is_binary(nonce) and is_integer(exp) do
    bytes = proof_signing_bytes(token, request, edge_xid, nonce, exp)
    %{nonce: nonce, exp: exp, signature: sign(session_key, bytes)}
  end

  @doc "Returns the domain-separated bytes signed by a holder proof."
  @spec proof_signing_bytes(binary(), map(), String.t(), binary(), integer()) :: binary()
  def proof_signing_bytes(token, request, edge_xid, nonce, exp) do
    challenge = proof_challenge(token, request, edge_xid, nonce, exp)

    dcbor_array([
      {:text, @signing_domain},
      {:text, @signing_purpose},
      {:bytes, challenge}
    ])
  end

  @doc "Returns canonical dCBOR for the Decision 7 eight-tuple."
  @spec proof_challenge(binary(), map(), String.t(), binary(), integer()) :: binary()
  def proof_challenge(token, request, edge_xid, nonce, exp) do
    method = fetch!(request, :method)
    target = fetch!(request, :request_target)
    body = Map.get(request, :body, Map.get(request, "body", <<>>))

    dcbor_array([
      {:text, @proof_version},
      {:bytes, Biscuit.blake3_hash(token)},
      {:text, method},
      {:text, target},
      {:bytes, Biscuit.blake3_hash(body)},
      {:text, edge_xid},
      {:bytes, nonce},
      {:uint, exp}
    ])
  end

  defp normalize_profile(claims, mode, now, opts) when mode in [:holder, :bearer] do
    subject = value(claims, :subject_xid)
    edge = value(claims, :edge_xid)
    exp = value(claims, :exp)

    with true <- is_binary(subject) and byte_size(subject) > 0,
         true <- valid_edge?(edge),
         true <- is_integer(exp) and exp > now,
         {:ok, rights} <- normalize_rights(value(claims, :rights)),
         {:ok, session_public, holder_fp} <- holder_fields(claims, mode),
         :ok <- bearer_ceiling(mode, rights, exp, Keyword.get(opts, :holder_policy)) do
      {:ok,
       %{
         subject_xid: subject,
         edge_xid: edge,
         mode: mode,
         issued_at: now,
         exp: exp,
         rights: rights,
         session_public: session_public,
         holder_fp: holder_fp
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_claims}
    end
  end

  defp normalize_profile(_, _, _, _), do: {:error, :unknown_mode}

  defp holder_fields(claims, :holder) do
    case value(claims, :session_public) do
      public when is_binary(public) and byte_size(public) == 32 ->
        {:ok, public, Biscuit.holder_fingerprint(public)}

      _ ->
        {:error, :invalid_session_key}
    end
  end

  defp holder_fields(claims, :bearer) do
    if is_nil(value(claims, :session_public)) do
      {:ok, nil, nil}
    else
      {:error, :bearer_has_holder}
    end
  end

  defp bearer_ceiling(:holder, _rights, _exp, _policy), do: :ok

  defp bearer_ceiling(:bearer, rights, exp, policy) when is_map(policy) do
    with {:ok, holder_rights} <- normalize_rights(value(policy, :rights)),
         holder_exp when is_integer(holder_exp) <- value(policy, :exp),
         true <- exp < holder_exp,
         true <- MapSet.subset?(MapSet.new(rights), MapSet.new(holder_rights)),
         true <- MapSet.new(rights) != MapSet.new(holder_rights) do
      :ok
    else
      _ -> {:error, :overbroad_bearer}
    end
  end

  defp bearer_ceiling(:bearer, _rights, _exp, _policy), do: {:error, :overbroad_bearer}

  defp normalize_rights(rights) when is_list(rights) and rights != [] do
    rights
    |> Enum.reduce_while([], fn
      {operation, resource}, acc when is_binary(operation) and is_binary(resource) ->
        {:cont, [{operation, resource} | acc]}

      [operation, resource], acc when is_binary(operation) and is_binary(resource) ->
        {:cont, [{operation, resource} | acc]}

      _, _acc ->
        {:halt, :error}
    end)
    |> case do
      :error -> {:error, :invalid_rights}
      normalized -> {:ok, normalized |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp normalize_rights(_), do: {:error, :invalid_rights}

  defp encode_profile(profile) do
    Jason.encode!([
      @profile_version,
      profile.subject_xid,
      profile.edge_xid,
      Atom.to_string(profile.mode),
      profile.issued_at,
      profile.exp,
      Enum.map(profile.rights, fn {operation, resource} -> [operation, resource] end),
      encode_optional(profile.session_public),
      encode_optional(profile.holder_fp)
    ])
  end

  defp decode_profile(bytes) do
    with {:ok, [@profile_version, subject, edge, mode, issued_at, exp, rights, public, fp]} <-
           Jason.decode(bytes),
         {:ok, mode} <- decode_mode(mode),
         {:ok, rights} <- normalize_rights(rights),
         {:ok, public} <- decode_optional(public),
         {:ok, fp} <- decode_optional(fp),
         profile = %{
           subject_xid: subject,
           edge_xid: edge,
           mode: mode,
           issued_at: issued_at,
           exp: exp,
           rights: rights,
           session_public: public,
           holder_fp: fp
         },
         true <- valid_decoded_profile?(profile),
         true <- encode_profile(profile) == bytes do
      {:ok, profile}
    else
      _ -> {:error, :invalid_profile}
    end
  end

  defp valid_decoded_profile?(%{mode: :holder, session_public: public, holder_fp: fp} = p) do
    is_binary(p.subject_xid) and byte_size(p.subject_xid) > 0 and valid_edge?(p.edge_xid) and
      is_integer(p.issued_at) and is_integer(p.exp) and p.exp > p.issued_at and
      is_binary(public) and byte_size(public) == 32 and is_binary(fp) and byte_size(fp) == 32 and
      Biscuit.holder_fingerprint(public) == fp
  end

  defp valid_decoded_profile?(%{mode: :bearer, session_public: nil, holder_fp: nil} = p) do
    is_binary(p.subject_xid) and byte_size(p.subject_xid) > 0 and valid_edge?(p.edge_xid) and
      is_integer(p.issued_at) and is_integer(p.exp) and p.exp > p.issued_at
  end

  defp valid_decoded_profile?(_), do: false

  defp bind_holder(biscuit, %{mode: :holder, holder_fp: fp}, private_hex) do
    public_hex = public_hex(private_hex)
    {:ok, Biscuit.append_holder(biscuit, public_hex, hex(fp))}
  end

  defp bind_holder(biscuit, %{mode: :bearer}, _private_hex), do: {:ok, biscuit}

  defp public_hex(private_hex) do
    private = Base.decode16!(private_hex, case: :mixed)
    {public, _} = :crypto.generate_key(:eddsa, :ed25519, private)
    Base.encode16(public, case: :lower)
  end

  defp pack(profile_bytes, biscuit) do
    @magic <> <<byte_size(profile_bytes)::unsigned-big-32>> <> profile_bytes <> biscuit
  end

  defp unpack(<<@magic, profile_size::unsigned-big-32, rest::binary>>)
       when profile_size > 0 and profile_size <= 65_536 and byte_size(rest) > profile_size do
    <<profile_bytes::binary-size(^profile_size), biscuit::binary>> = rest

    with {:ok, profile} <- decode_profile(profile_bytes) do
      {:ok, profile_bytes, biscuit, profile}
    end
  end

  defp unpack(_), do: {:error, :invalid_token}

  defp trusted_root(root) when is_binary(root) and byte_size(root) == 64 do
    case Base.decode16(root, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == 32 -> :ok
      _ -> {:error, :foreign_root}
    end
  end

  defp trusted_root(_), do: {:error, :foreign_root}

  defp current(%{exp: exp}, now) when is_integer(now) and now < exp, do: :ok
  defp current(_, _), do: {:error, :expired}

  defp expected_audience(%{edge_xid: edge}, edge), do: :ok
  defp expected_audience(_, _), do: {:error, :wrong_audience}

  defp permitted(profile, request) do
    operation = value(request, :operation)
    resource = value(request, :resource)

    if {operation, resource} in profile.rights or {operation, "*"} in profile.rights do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp holder_evidence(%{mode: :bearer}, _token, request, _now) do
    if is_nil(value(request, :proof)), do: {:ok, false, nil}, else: {:error, :unexpected_proof}
  end

  defp holder_evidence(%{mode: :holder} = profile, token, request, now) do
    with %{nonce: nonce, exp: proof_exp, signature: signature} <-
           atomize_proof(value(request, :proof)),
         true <- is_binary(nonce) and byte_size(nonce) == 32,
         true <- is_integer(proof_exp) and now < proof_exp and proof_exp <= profile.exp,
         true <- is_binary(signature) and byte_size(signature) == 64,
         :ok <- valid_request_bytes(request),
         signing_bytes <-
           proof_signing_bytes(token, request, profile.edge_xid, nonce, proof_exp),
         true <- verify(profile.session_public, signing_bytes, signature) do
      {:ok, true, nonce}
    else
      _ -> {:error, :invalid_holder_proof}
    end
  end

  defp runtime_authorize(biscuit, root, profile, profile_bytes, inject_holder) do
    fp = if profile.holder_fp, do: hex(profile.holder_fp), else: ""

    case Biscuit.authorize(
           biscuit,
           root,
           fp,
           authority_resource(profile_bytes),
           authority_operation(profile.mode),
           inject_holder
         ) do
      :ok -> :ok
      {:error, _} -> {:error, :invalid_capability}
    end
  end

  defp consume_nonce(%{mode: :bearer}, nil, _request, _now, _opts), do: :ok

  defp consume_nonce(%{mode: :holder}, nonce, request, now, opts) do
    proof_exp = value(value(request, :proof), :exp)

    case Keyword.get(opts, :nonce_store) do
      fun when is_function(fun, 3) -> normalize_nonce_result(fun.(nonce, now, proof_exp))
      module when is_atom(module) -> normalize_nonce_result(module.consume(nonce, now, proof_exp))
      _ -> {:error, :unknown_nonce}
    end
  rescue
    _ -> {:error, :unknown_nonce}
  end

  defp normalize_nonce_result(:ok), do: :ok
  defp normalize_nonce_result({:ok, nonce_exp}) when is_integer(nonce_exp), do: :ok
  defp normalize_nonce_result(_), do: {:error, :unknown_nonce}

  defp valid_request_bytes(request) do
    method = value(request, :method)
    target = value(request, :request_target)
    body = Map.get(request, :body, Map.get(request, "body", <<>>))

    if is_binary(method) and method != "" and method == String.upcase(method, :ascii) and
         String.match?(method, ~r/^[A-Z]+$/) and is_binary(target) and target != "" and
         is_binary(body) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp authority_resource(profile_bytes) do
    @profile_version <> ":" <> hex(Biscuit.blake3_hash(profile_bytes))
  end

  defp authority_operation(mode), do: "login_mode:" <> Atom.to_string(mode)

  defp valid_edge?(edge),
    do: is_binary(edge) and byte_size(edge) == 64 and String.match?(edge, ~r/^[0-9a-f]{64}$/)

  defp decode_mode("holder"), do: {:ok, :holder}
  defp decode_mode("bearer"), do: {:ok, :bearer}
  defp decode_mode(_), do: {:error, :unknown_mode}

  defp encode_optional(nil), do: nil
  defp encode_optional(bytes), do: Base.encode64(bytes)
  defp decode_optional(nil), do: {:ok, nil}
  defp decode_optional(text) when is_binary(text), do: Base.decode64(text)
  defp decode_optional(_), do: :error

  defp atomize_proof(%{} = proof) do
    %{
      nonce: value(proof, :nonce),
      exp: value(proof, :exp),
      signature: value(proof, :signature)
    }
  end

  defp atomize_proof(_), do: nil

  defp sign(%{ed25519_secret: secret}, bytes), do: sign(secret, bytes)

  defp sign(secret, bytes) when is_binary(secret),
    do: :crypto.sign(:eddsa, :none, bytes, [secret, :ed25519])

  defp verify(public, bytes, signature),
    do: :crypto.verify(:eddsa, :none, bytes, signature, [public, :ed25519])

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_, _), do: nil

  defp fetch!(map, key) do
    case value(map, key) do
      nil -> raise ArgumentError, "missing #{key}"
      value -> value
    end
  end

  # The proof schema needs only arrays, UTF-8 text, byte strings, and
  # non-negative integers. Definite lengths and shortest integer encodings are
  # canonical dCBOR for these values.
  defp dcbor_array(items) do
    [cbor_head(4, length(items)) | Enum.map(items, &dcbor_item/1)] |> IO.iodata_to_binary()
  end

  defp dcbor_item({:text, text}) when is_binary(text),
    do: [cbor_head(3, byte_size(text)), text]

  defp dcbor_item({:bytes, bytes}) when is_binary(bytes),
    do: [cbor_head(2, byte_size(bytes)), bytes]

  defp dcbor_item({:uint, number}) when is_integer(number) and number >= 0,
    do: cbor_head(0, number)

  defp cbor_head(major, number) when number < 24, do: <<major::3, number::5>>
  defp cbor_head(major, number) when number < 0x100, do: <<major::3, 24::5, number::8>>
  defp cbor_head(major, number) when number < 0x1_0000, do: <<major::3, 25::5, number::16>>
  defp cbor_head(major, number) when number < 0x1_0000_0000, do: <<major::3, 26::5, number::32>>
  defp cbor_head(major, number), do: <<major::3, 27::5, number::64>>
end
