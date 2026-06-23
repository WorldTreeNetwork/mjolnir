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
      GET    /manifests/:hash              — fetch a manifest envelope
      GET    /manifests/:hash/ots          — fetch the OpenTimestamps receipt
      PUT    /manifests/:hash/ots          — upload an OpenTimestamps receipt

  Chunk-upload framing: `<8-byte BE u64 ct_len><ciphertext><8-byte BE u64 ob_len><outboard>`.
  """

  use Plug.Router
  require Logger

  alias Mjolnir.SecretStore

  alias Mjolnir.Sites.{
    AliasRecord,
    HeadIndex,
    HeadRecord,
    Manifest,
    ManifestIndex,
    OpenTimestamps,
    Server,
    Store
  }

  plug(:match)
  plug(:dispatch)

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

  ## HEAD pointer

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

  defp head_key(site_name), do: "sites/#{site_name}/HEAD"

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
