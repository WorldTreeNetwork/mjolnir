defmodule Mjolnir.API.SitesRouter do
  @moduledoc """
  HTTP endpoints for the IdentiKey Sites subsystem (Phase 1: public mode).

  Mounted under `/api/sites` from `Mjolnir.API.Router` via `forward`. The
  parent router bypasses body parsing for this prefix because most endpoints
  read raw bytes (envelopes, ciphertext, outboards, OTS receipts).

  See `docs/plans/initiatives/identikey-sites.md` §6.1 for the publish flow.

  ## Endpoints

      POST   /:fp/:name/snapshot           — upload a signed manifest envelope
      POST   /:fp/:name/head               — update the HEAD pointer
      GET    /:fp/:name/head               — read current HEAD
      GET    /:fp/:name/files/*path        — debug serve path (public mode)
      PUT    /blob/:hash                   — upload chunk (framed: len|ct|len|ob)
      GET    /blob/:hash                   — fetch ciphertext
      GET    /blob/:hash/outboard          — fetch Bao outboard
      POST   /recordings                   — owner wrap for a stored ciphertext hash
      POST   /recordings/:hash/friends     — one friend wrap for that hash
      GET    /recordings/:hash             — owner index (registering JWT sub only)
      GET    /manifests/:hash              — fetch a manifest envelope
      GET    /manifests/:hash/ots          — fetch the OpenTimestamps receipt
      PUT    /manifests/:hash/ots          — upload an OpenTimestamps receipt

  Chunk-upload framing: `<8-byte BE u64 ct_len><ciphertext><8-byte BE u64 ob_len><outboard>`.

  ## Service-token scoping

  When a request authenticates with a `Mjolnir.Sites.Token`, `Auth` puts the
  token on `conn.assigns[:sites_token]` and `enforce_token_binding/2` (below)
  requires the token's bound fingerprint to equal the `:fp` path parameter,
  and its bound site — when it has one — to equal `:name`. Mismatches are 403.

  Three routes carry no `:fp` and are therefore *not* fingerprint-scoped:

    * `PUT|GET /blob/:hash` — chunks are content-addressed and immutable.
      `Store.put_chunk/3` recomputes the Blake3 hash of the supplied ciphertext
      and refuses to write unless it equals `:hash`, so a chunk write can only
      ever produce the one byte-string that hashes to that name. There is no
      cross-tenant *write* to prevent: a chunk is not owned by a fingerprint,
      it is named by its own content. Residual risk is storage growth from
      orphan chunks and the ability to read any chunk's ciphertext by hash —
      see the module doc of `Mjolnir.Sites.Token` and the follow-ups noted
      there.
    * `GET /manifests/:hash[/ots]` — read-only, and public-mode manifests are
      published to be served publicly.
    * `GET /aliases/lookup` — read-only resolver.
  """

  use Plug.Router
  require Logger

  alias Mjolnir.SecretStore

  alias Mjolnir.Sites.{
    AliasRecord,
    FallbackPolicy,
    HeadIndex,
    HeadRecord,
    Manifest,
    ManifestIndex,
    Materializer,
    OpenTimestamps,
    Server,
    Store,
    WrapShape
  }

  plug(:match)
  plug(:enforce_token_binding)
  plug(:dispatch)

  # A Sites service token is bound to one IdentiKey fingerprint (and optionally
  # one site). Enforce that binding against the matched route's path parameters
  # before any handler runs, so a CI credential for one site cannot publish
  # under another fingerprint.
  #
  # Runs after `:match` because that is what populates `conn.path_params`.
  # Requests authenticated any other way (loopback bypass, JWT) carry no
  # `:sites_token` assign and pass through unchanged — this plug only ever
  # narrows what a sites token can reach.
  defp enforce_token_binding(conn, _opts) do
    case conn.assigns[:sites_token] do
      nil -> conn
      token -> check_binding(conn, token)
    end
  end

  defp check_binding(conn, token) do
    fp = conn.path_params["fp"]
    name = conn.path_params["name"]

    cond do
      # Routes with no `:fp` in their path (/blob/:hash, /manifests/:hash,
      # /aliases/lookup). Content-addressed or read-only; see the module doc.
      is_nil(fp) ->
        conn

      not Mjolnir.Sites.Token.authorizes?(token, fp, name) ->
        Logger.warning(
          "Sites token #{token.id} (fp=#{token.identikey_fp} site=#{inspect(token.site_name)}) " <>
            "denied for fp=#{fp} site=#{inspect(name)}"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, Jason.encode!(%{error: "token_scope_mismatch"}))
        |> halt()

      true ->
        conn
    end
  end

  ## Snapshot upload

  post "/:fp/:name/snapshot" do
    with {:ok, bytes, conn} <- read_full_body(conn),
         {:ok, manifest} <- Manifest.parse(bytes),
         :ok <- check_manifest_matches(manifest, fp, name) do
      hash = Manifest.snapshot_hash(bytes)

      case Store.put_manifest(hash, bytes) do
        :ok ->
          # Index for fast metadata lookup. Failure logged but non-fatal — the
          # envelope is already durable on disk and can be re-indexed later.
          _ = ManifestIndex.upsert(hash, manifest)

          missing =
            manifest.entries
            |> Enum.reject(&Store.has_chunk?(&1.bao_hash))
            |> Enum.map(& &1.bao_hash)

          ots_status = submit_ots(hash, bytes)

          json(conn, 201, %{snapshot_hash: hash, missing_chunks: missing, ots_status: ots_status})

        {:error, reason} ->
          Logger.error("snapshot put failed: #{inspect(reason)}")
          json(conn, 500, %{error: "manifest_write_failed"})
      end
    else
      {:error, {:bad_manifest, _}} -> json(conn, 400, %{error: "bad_manifest"})
      {:error, :identikey_mismatch} -> json(conn, 400, %{error: "identikey_mismatch"})
      {:error, :site_mismatch} -> json(conn, 400, %{error: "site_mismatch"})
      {:error, reason} -> json(conn, 400, %{error: inspect(reason)})
    end
  end

  ## Identity registration

  # Deposit the self-authenticating `identity/pubkey` bootstrap record so that
  # subsequent signed records (HEAD, alias) under this fingerprint can be
  # verified. The body is `{"pubkey": "<base64 ed25519>"}` with no signature;
  # SecretStore.put verifies that fingerprint(pubkey) == fp. Idempotent.
  put "/:fp/identity" do
    with {:ok, bytes, conn} <- read_full_body(conn),
         :ok <- SecretStore.put(fp, "identity/pubkey", bytes) do
      json(conn, 201, %{ok: true, identikey_fp: fp})
    else
      {:error, :fingerprint_mismatch} -> json(conn, 400, %{error: "fingerprint_mismatch"})
      {:error, :missing_pubkey} -> json(conn, 400, %{error: "missing_pubkey"})
      {:error, reason} -> json(conn, 400, %{error: inspect(reason)})
    end
  end

  ## HEAD pointer

  post "/:fp/:name/commit" do
    with {:ok, bytes, conn} <- read_full_body(conn),
         {:ok, payload} <- Jason.decode(bytes),
         {:ok, head_bytes} <- decode_commit_field(payload, "head"),
         {:ok, policy_bytes} <- decode_optional_commit_field(payload, "fallback"),
         {:ok, record} <- HeadRecord.parse(head_bytes),
         :ok <- check_head_matches(record, fp, name),
         {:ok, policy} <- parse_commit_policy(policy_bytes, fp, name, record.sequence),
         {:ok, committed} <-
           commit_head_and_policy(fp, name, head_bytes, record, policy_bytes, policy) do
      _ = HeadIndex.upsert(committed)
      materialize(committed)
      json(conn, 200, %{ok: true, sequence: committed.sequence})
    else
      {:error, :sequence_regression} -> json(conn, 409, %{error: "sequence_regression"})
      {:error, reason} -> json(conn, 400, %{error: inspect(reason)})
    end
  end

  post "/:fp/:name/head" do
    with {:ok, bytes, conn} <- read_full_body(conn),
         {:ok, record} <- HeadRecord.parse(bytes),
         :ok <- check_head_matches(record, fp, name),
         :ok <- check_head_monotonic(record, fp, name) do
      case SecretStore.put(fp, head_key(name), bytes) do
        :ok ->
          # Index for hot-path serve lookups. Best-effort; envelope is the
          # source of truth on disk.
          _ = HeadIndex.upsert(record)
          materialize(record)
          json(conn, 200, %{ok: true, sequence: record.sequence})

        {:error, reason} ->
          json(conn, 500, %{error: inspect(reason)})
      end
    else
      {:error, {:bad_head_record, _}} -> json(conn, 400, %{error: "bad_head_record"})
      {:error, :identikey_mismatch} -> json(conn, 400, %{error: "identikey_mismatch"})
      {:error, :site_mismatch} -> json(conn, 400, %{error: "site_mismatch"})
      {:error, :sequence_regression} -> json(conn, 409, %{error: "sequence_regression"})
      {:error, reason} -> json(conn, 400, %{error: inspect(reason)})
    end
  end

  get "/:fp/:name/head" do
    case SecretStore.get(fp, head_key(name)) do
      {:ok, bytes} -> send_binary(conn, 200, bytes)
      :not_found -> json(conn, 404, %{error: "no_head"})
      {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
    end
  end

  ## Debug serve path

  get "/:fp/:name/files/*path" do
    serve_path = "/" <> Enum.join(path, "/")

    case Server.serve(fp, name, serve_path) do
      {:ok, %{status: status, content_type: ct, content_encoding: ce, body: body}} ->
        # Pass nil charset so the manifest-supplied content_type is used verbatim
        # (the manifest already includes "; charset=..." when relevant).
        conn = put_resp_content_type(conn, ct, nil)
        conn = if ce, do: put_resp_header(conn, "content-encoding", ce), else: conn
        send_resp(conn, status, body)

      {:error, :not_found} ->
        json(conn, 404, %{error: "not_found", path: serve_path})

      {:error, :no_head} ->
        json(conn, 404, %{error: "no_head"})

      {:error, :no_manifest} ->
        json(conn, 503, %{error: "manifest_unavailable"})

      {:error, :chunk_missing} ->
        json(conn, 503, %{error: "chunk_missing"})

      {:error, reason} ->
        json(conn, 500, %{error: inspect(reason)})
    end
  end

  ## Chunks

  put "/blob/:hash" do
    with {:ok, framed, conn} <- read_full_body(conn),
         {:ok, ciphertext, outboard} <- unframe_chunk(framed),
         :ok <- Store.put_chunk(hash, ciphertext, outboard) do
      json(conn, 201, %{ok: true, hash: hash})
    else
      {:error, :bad_framing} -> json(conn, 400, %{error: "bad_framing"})
      {:error, reason} -> json(conn, 400, %{error: inspect(reason)})
    end
  end

  get "/blob/:hash" do
    case Store.get_chunk(hash) do
      {:ok, %{ciphertext: ct}} -> send_binary(conn, 200, ct)
      :not_found -> json(conn, 404, %{error: "chunk_missing"})
      {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/blob/:hash/outboard" do
    case Store.get_chunk(hash) do
      {:ok, %{outboard: ob}} -> send_binary(conn, 200, ob)
      :not_found -> json(conn, 404, %{error: "chunk_missing"})
      {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
    end
  end

  ## Manifests + OTS

  get "/manifests/:hash" do
    case Store.get_manifest(hash) do
      {:ok, bytes} -> send_binary(conn, 200, bytes)
      :not_found -> json(conn, 404, %{error: "manifest_not_found"})
      {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/manifests/:hash/ots" do
    case Store.get_ots(hash) do
      {:ok, bytes} -> send_binary(conn, 200, bytes)
      :not_found -> json(conn, 404, %{error: "ots_not_found"})
      {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
    end
  end

  put "/manifests/:hash/ots" do
    with {:ok, bytes, conn} <- read_full_body(conn),
         :ok <- Store.put_ots(hash, bytes) do
      json(conn, 201, %{ok: true})
    else
      {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
    end
  end

  ## Alias resolver (T3)

  get "/aliases/lookup" do
    conn = Plug.Conn.fetch_query_params(conn)
    host = conn.query_params["host"]

    cond do
      is_nil(host) or host == "" ->
        json(conn, 400, %{error: "missing_host"})

      true ->
        case SecretStore.lookup_alias(host) do
          {:ok, {fp, site_name}} ->
            json(conn, 200, %{identikey_fp: fp, site_name: site_name})

          :not_found ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  ## Alias upload + tombstone (T4)

  put "/:fp/:name/aliases/:fqdn" do
    with {:ok, bytes, conn} <- read_full_body(conn),
         {:ok, record} <- AliasRecord.parse(bytes),
         :ok <- check_alias_matches(record, fp, name, fqdn),
         :ok <- check_alias_monotonic(record, fp, name, fqdn) do
      case SecretStore.put(fp, alias_key(name, fqdn), bytes) do
        :ok ->
          json(conn, 201, %{ok: true})

        {:error, :alias_already_claimed} ->
          json(conn, 409, %{error: "alias_already_claimed"})

        {:error, reason} ->
          json(conn, 500, %{error: inspect(reason)})
      end
    else
      {:error, {:bad_alias_record, _}} -> json(conn, 400, %{error: "bad_alias_record"})
      {:error, :identikey_mismatch} -> json(conn, 400, %{error: "identikey_mismatch"})
      {:error, :site_mismatch} -> json(conn, 400, %{error: "site_mismatch"})
      {:error, :fqdn_mismatch} -> json(conn, 400, %{error: "fqdn_mismatch"})
      {:error, :sequence_regression} -> json(conn, 409, %{error: "sequence_regression"})
      {:error, :bad_signature} -> json(conn, 400, %{error: "bad_signature"})
      {:error, reason} -> json(conn, 400, %{error: inspect(reason)})
    end
  end

  delete "/:fp/:name/aliases/:fqdn" do
    with {:ok, bytes, conn} <- read_full_body(conn),
         {:ok, record} <- AliasRecord.parse(bytes),
         :ok <- check_alias_matches(record, fp, name, fqdn),
         :ok <- check_alias_monotonic(record, fp, name, fqdn) do
      case SecretStore.delete(fp, alias_key(name, fqdn), bytes) do
        :ok ->
          send_resp(conn, 204, "")

        {:error, reason} ->
          json(conn, 500, %{error: inspect(reason)})
      end
    else
      {:error, {:bad_alias_record, _}} -> json(conn, 400, %{error: "bad_alias_record"})
      {:error, :identikey_mismatch} -> json(conn, 400, %{error: "identikey_mismatch"})
      {:error, :site_mismatch} -> json(conn, 400, %{error: "site_mismatch"})
      {:error, :fqdn_mismatch} -> json(conn, 400, %{error: "fqdn_mismatch"})
      {:error, :sequence_regression} -> json(conn, 409, %{error: "sequence_regression"})
      {:error, :bad_signature} -> json(conn, 400, %{error: "bad_signature"})
      {:error, reason} -> json(conn, 400, %{error: inspect(reason)})
    end
  end

  # Reject alias writes/tombstones whose sequence does not strictly increase
  # the stored record's sequence. Prevents replay attacks across publishes.
  defp check_alias_monotonic(%AliasRecord{sequence: seq}, fp, name, fqdn) do
    key = alias_key(name, fqdn)

    case SecretStore.get(fp, key) do
      :not_found ->
        :ok

      {:ok, current_bytes} ->
        case AliasRecord.parse(current_bytes) do
          {:ok, current} ->
            if seq > current.sequence, do: :ok, else: {:error, :sequence_regression}

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  ## Recording index

  # JWT `:user` only. Checked before the body is read and before any blob probe,
  # so a biscuit, a Sites token, the operator, a ceremony, or a public caller
  # never reaches the door or the recordings directory.
  post "/recordings" do
    case recording_user(conn) do
      :no -> json(conn, 403, %{error: "forbidden"})
      {:ok, sub} -> register_recording(conn, sub)
    end
  end

  post "/recordings/:hash/friends" do
    case recording_user(conn) do
      :no -> json(conn, 403, %{error: "forbidden"})
      {:ok, sub} -> add_recording_friend(conn, sub, hash)
    end
  end

  get "/recordings/:hash" do
    case recording_user(conn) do
      :no -> json(conn, 403, %{error: "forbidden"})
      {:ok, sub} -> show_recording(conn, sub, hash)
    end
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  ## Helpers

  # Submit envelope bytes to OTS calendars. Returns an ots_status string for
  # inclusion in the JSON response. Failures are non-fatal: the snapshot is
  # already persisted; OTS is best-effort at publish time.
  defp submit_ots(hash, envelope_bytes) do
    if OpenTimestamps.available?() do
      case OpenTimestamps.submit(envelope_bytes) do
        {:ok, receipt_bytes} ->
          case Store.put_ots(hash, receipt_bytes) do
            :ok ->
              Logger.info("Sites: OTS receipt submitted for #{hash}")
              "submitted"

            {:error, reason} ->
              Logger.warning("Sites: OTS receipt storage failed for #{hash}: #{inspect(reason)}")
              "failed"
          end

        {:error, reason} ->
          Logger.warning("Sites: OTS submission failed for #{hash}: #{inspect(reason)}")
          "failed"
      end
    else
      "skipped_unavailable"
    end
  end

  # Write the newly-published snapshot out as a plaintext directory the gateway
  # can serve with a static file handler. Best-effort: the materialized tree is
  # a derived cache rebuildable from the manifest + chunk store, and
  # `Server.serve/3` still answers for sites that have none, so a failure here
  # must not fail the publish.
  defp materialize(%HeadRecord{} = record) do
    case Materializer.materialize(record.identikey_fp, record.site_name, record.snapshot_hash) do
      {:ok, dir} ->
        Logger.info("Sites: materialized #{record.snapshot_hash} → #{dir}")

      {:error, reason} ->
        Logger.warning(
          "Sites: materialization failed for #{record.snapshot_hash}: #{inspect(reason)}"
        )
    end
  end

  defp head_key(site_name), do: "sites/#{site_name}/HEAD"

  defp fallback_key(site_name), do: "sites/#{site_name}/fallback"

  defp decode_commit_field(payload, key) do
    with value when is_binary(value) <- Map.get(payload, key),
         {:ok, decoded} <- Base.decode64(value) do
      {:ok, decoded}
    else
      _ -> {:error, {:bad_commit_field, key}}
    end
  end

  defp decode_optional_commit_field(payload, key) do
    case Map.get(payload, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> Base.decode64(value)
      _ -> {:error, {:bad_commit_field, key}}
    end
  end

  defp parse_commit_policy(nil, _fp, _name, _sequence), do: {:ok, nil}

  defp parse_commit_policy(bytes, fp, name, sequence) do
    with {:ok, policy} <- FallbackPolicy.parse(bytes),
         :ok <- equal_or_error(policy.identikey_fp, fp, :identikey_mismatch),
         :ok <- equal_or_error(policy.site_name, name, :site_mismatch),
         :ok <- equal_or_error(policy.sequence, sequence, :sequence_mismatch),
         :ok <- FallbackPolicy.verify(policy) do
      {:ok, policy}
    end
  end

  defp equal_or_error(value, value, _error), do: :ok
  defp equal_or_error(_left, _right, error), do: {:error, error}

  defp commit_head_and_policy(fp, name, head_bytes, record, policy_bytes, _policy) do
    :global.trans({{__MODULE__, fp, name}, self()}, fn ->
      with :ok <- check_head_monotonic(record, fp, name) do
        previous = SecretStore.get(fp, fallback_key(name))

        with :ok <- write_policy_record(fp, name, policy_bytes),
             :ok <- SecretStore.put(fp, head_key(name), head_bytes) do
          {:ok, record}
        else
          {:error, _} = error ->
            _ = restore_policy_record(fp, name, previous)
            error
        end
      end
    end)
  end

  # The new record is verified above. Keeping this dispatch here avoids
  # changing SecretStore's existing HEAD/manifest canonical signed field sets.
  defp write_policy_record(fp, name, nil) do
    case File.rm(policy_record_path(fp, name)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_policy_record(fp, name, bytes) when is_binary(bytes) do
    path = policy_record_path(fp, name)
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, bytes),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp restore_policy_record(fp, name, {:ok, bytes}), do: write_policy_record(fp, name, bytes)
  defp restore_policy_record(fp, name, :not_found), do: write_policy_record(fp, name, nil)
  defp restore_policy_record(_fp, _name, {:error, _}), do: :ok

  defp policy_record_path(fp, name) do
    if safe_record_component?(fp) and safe_record_component?(name) do
      Path.join([SecretStore.root(), fp, "sites", name, "fallback"])
    else
      raise ArgumentError, "unsafe site policy path"
    end
  end

  defp safe_record_component?(value) do
    is_binary(value) and value != "" and value not in [".", ".."] and
      not String.contains?(value, ["/", "\\", <<0>>])
  end

  defp alias_key(site_name, fqdn), do: "sites/#{site_name}/aliases/#{fqdn}"

  defp check_alias_matches(
         %AliasRecord{identikey_fp: rfp, site_name: rname, fqdn: rfqdn},
         fp,
         name,
         fqdn
       ) do
    cond do
      rfp != fp -> {:error, :identikey_mismatch}
      rname != name -> {:error, :site_mismatch}
      rfqdn != fqdn -> {:error, :fqdn_mismatch}
      true -> :ok
    end
  end

  defp check_manifest_matches(%Manifest{identikey_fp: fp, site_name: name}, fp, name), do: :ok

  defp check_manifest_matches(%Manifest{identikey_fp: mfp}, fp, _) when mfp != fp,
    do: {:error, :identikey_mismatch}

  defp check_manifest_matches(%Manifest{}, _, _), do: {:error, :site_mismatch}

  defp check_head_matches(%HeadRecord{identikey_fp: fp, site_name: name}, fp, name), do: :ok

  defp check_head_matches(%HeadRecord{identikey_fp: hfp}, fp, _) when hfp != fp,
    do: {:error, :identikey_mismatch}

  defp check_head_matches(%HeadRecord{}, _, _), do: {:error, :site_mismatch}

  defp check_head_monotonic(%HeadRecord{sequence: seq}, fp, name) do
    case SecretStore.get(fp, head_key(name)) do
      :not_found ->
        :ok

      {:ok, current_bytes} ->
        case HeadRecord.parse(current_bytes) do
          {:ok, current} ->
            if seq > current.sequence, do: :ok, else: {:error, :sequence_regression}

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp unframe_chunk(
         <<ct_len::big-unsigned-64, ct::binary-size(ct_len), ob_len::big-unsigned-64,
           ob::binary-size(ob_len)>>
       ) do
    {:ok, ct, ob}
  end

  defp unframe_chunk(_), do: {:error, :bad_framing}

  # 16 KiB covers a 4096-byte wrap in unpadded base64url plus the JSON envelope.
  # The ciphertext itself stays on `PUT /blob/:hash` (64 MiB).
  @recording_body_max 16_384

  defp recording_user(conn) do
    case conn.assigns do
      %{principal_kind: :user, user_id: sub} when is_binary(sub) and sub != "" -> {:ok, sub}
      _ -> :no
    end
  end

  defp register_recording(conn, sub) do
    case read_json_body(conn) do
      {:error, _, conn} ->
        json(conn, 400, %{error: "bad_body"})

      {:ok, bytes, conn} ->
        with {:ok, hash, owner_xid, wrap_b64} <- decode_register_body(bytes),
             :ok <- check_hash(hash),
             :ok <- check_xid(owner_xid),
             {:ok, wrap} <- decode_wrap_body(wrap_b64) do
          if Store.chunk_present?(hash) do
            finish_register(conn, sub, hash, owner_xid, wrap)
          else
            json(conn, 404, %{error: "blob_missing"})
          end
        else
          :bad_body -> json(conn, 400, %{error: "bad_body"})
          :bad_hash -> json(conn, 400, %{error: "bad_hash"})
          :bad_xid -> json(conn, 400, %{error: "bad_xid"})
          :bad_wrap -> json(conn, 400, %{error: "bad_wrap"})
        end
    end
  end

  defp finish_register(conn, sub, hash, owner_xid, wrap) do
    case Store.register_recording(sub, hash, owner_xid, wrap) do
      {:ok, which} when which in [:created, :exists] ->
        status = if which == :created, do: 201, else: 200

        case Store.fetch_recording(hash) do
          {:ok, row} -> json(conn, status, public_recording(row))
          other -> json(conn, 500, %{error: inspect(other)})
        end

      {:error, :conflict} ->
        json(conn, 409, %{error: "wrap_conflict"})

      {:error, :not_owner} ->
        json(conn, 403, %{error: "not_owner"})

      {:error, reason} ->
        json(conn, 500, %{error: inspect(reason)})
    end
  end

  defp add_recording_friend(conn, sub, hash) do
    case read_json_body(conn) do
      {:error, _, conn} ->
        json(conn, 400, %{error: "bad_body"})

      {:ok, bytes, conn} ->
        with :ok <- check_hash(hash),
             {:ok, friend_xid, wrap_b64} <- decode_friend_body(bytes),
             :ok <- check_xid(friend_xid),
             {:ok, wrap} <- decode_wrap_body(wrap_b64) do
          finish_friend(conn, sub, hash, friend_xid, wrap)
        else
          :bad_body -> json(conn, 400, %{error: "bad_body"})
          :bad_hash -> json(conn, 400, %{error: "bad_hash"})
          :bad_xid -> json(conn, 400, %{error: "bad_xid"})
          :bad_wrap -> json(conn, 400, %{error: "bad_wrap"})
        end
    end
  end

  defp finish_friend(conn, sub, hash, friend_xid, wrap) do
    case Store.add_recording_friend(sub, hash, friend_xid, wrap) do
      {:ok, which} when which in [:created, :exists] ->
        status = if which == :created, do: 201, else: 200

        case Store.fetch_recording(hash) do
          {:ok, row} -> json(conn, status, public_recording(row))
          other -> json(conn, 500, %{error: inspect(other)})
        end

      {:error, :not_found} ->
        json(conn, 404, %{error: "recording_missing"})

      {:error, :not_owner} ->
        json(conn, 403, %{error: "not_owner"})

      {:error, :self} ->
        json(conn, 400, %{error: "owner_is_not_friend"})

      {:error, :conflict} ->
        json(conn, 409, %{error: "wrap_conflict"})

      {:error, reason} ->
        json(conn, 500, %{error: inspect(reason)})
    end
  end

  defp show_recording(conn, sub, hash) do
    case Store.fetch_recording(hash) do
      {:error, :bad_hash} ->
        json(conn, 400, %{error: "bad_hash"})

      :not_found ->
        json(conn, 404, %{error: "recording_missing"})

      {:ok, %{"owner_sub" => ^sub} = row} ->
        json(conn, 200, public_recording(row))

      {:ok, _} ->
        json(conn, 403, %{error: "not_owner"})

      {:error, reason} ->
        json(conn, 500, %{error: inspect(reason)})
    end
  end

  defp public_recording(row) do
    %{
      hash: row["hash"],
      owner_xid: row["owner_xid"],
      wrap: row["owner_wrap"],
      friends:
        Enum.map(row["friends"], fn friend ->
          %{"friend_xid" => friend["friend_xid"], "wrap" => friend["wrap"]}
        end)
    }
  end

  defp decode_register_body(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"hash" => hash, "owner_xid" => owner_xid, "wrap" => wrap}}
      when is_binary(hash) and is_binary(owner_xid) and is_binary(wrap) ->
        {:ok, hash, owner_xid, wrap}

      _ ->
        :bad_body
    end
  end

  defp decode_friend_body(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"friend_xid" => friend_xid, "wrap" => wrap}}
      when is_binary(friend_xid) and is_binary(wrap) ->
        {:ok, friend_xid, wrap}

      _ ->
        :bad_body
    end
  end

  defp decode_wrap_body(text) do
    case Base.url_decode64(text, padding: false) do
      {:ok, bytes} -> if WrapShape.valid?(bytes), do: {:ok, bytes}, else: :bad_wrap
      :error -> :bad_wrap
    end
  end

  defp check_hash(hash) do
    if Store.valid_blob_hash?(hash), do: :ok, else: :bad_hash
  end

  defp check_xid(xid) do
    if Store.valid_xid?(xid), do: :ok, else: :bad_xid
  end

  defp read_json_body(conn) do
    case Plug.Conn.read_body(conn, length: @recording_body_max) do
      {:ok, bytes, conn} -> {:ok, bytes, conn}
      {:more, _partial, conn} -> {:error, :body_too_large, conn}
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp read_full_body(conn) do
    case Plug.Conn.read_body(conn, length: 64 * 1024 * 1024) do
      {:ok, bytes, conn} -> {:ok, bytes, conn}
      {:more, _partial, _conn} -> {:error, :body_too_large}
      {:error, _} = err -> err
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp send_binary(conn, status, bytes) do
    conn
    |> put_resp_content_type("application/octet-stream")
    |> send_resp(status, bytes)
  end
end
