defmodule Mjolnir.Aie.Execute do
  @moduledoc """
  Holder-bound AIE mint and enqueue ceremonies. Offers belong to VM beings;
  the durable host root issues Biscuits. Only the scoped sidecar admits loads.

  Proofs use a NUL-terminated domain and uint32 big-endian length-prefixed
  fields (see `signing_message/1`). Nonces are consumed by enqueue, never by
  a retry. The original proof is retained in the pending table.
  """
  alias Mjolnir.Aie.{Offer, Guild}
  alias Mjolnir.AIE.{Pending, Occupancy}
  alias Mjolnir.{Biscuit, Secrets.Nonces}

  @max_input 1_048_576
  def max_input, do: @max_input

  def audience do
    Biscuit.authority().public_hex
    |> Base.decode16!(case: :lower)
    |> Biscuit.holder_fingerprint()
    |> Base.encode16(case: :lower)
  end

  def challenge, do: %{nonce: Nonces.issue(), audience: audience()}

  def share(owner, id) do
    with {:ok, ref} <- Offer.mint(owner, id),
         {:ok, offer, bytes} <- Offer.fetch(owner, id),
         :ok <- being_live(offer) do
      {:ok, Map.merge(ref, %{resource: resource(ref), offer: Jason.decode!(bytes)})}
    end
  end

  def resource(ref), do: "#{ref.owner_fp}/#{ref.offer_id}/#{ref.incarnation}"

  @doc "Mint for the owner, or refresh an existing holder's execute grant."
  def mint(params) do
    with {:ok, offer, public, _input} <- prove(params, "MINT"),
         {:ok, target} <- decode(params["holder_public_key"], 32),
         :ok <- mint_grant(params, offer, public),
         :ok <- consume(params["nonce"]) do
      root = Biscuit.authority()
      holder = hex(Biscuit.holder_fingerprint(target))
      token = Biscuit.mint(root.private_hex, params["resource"], "aie-execute")
      token = Biscuit.append_holder(token, root.public_hex, holder)
      {:ok, %{biscuit: Base.encode64(token), audience: audience(), resource: params["resource"]}}
    else
      _ -> {:error, :forbidden}
    end
  rescue
    _ -> {:error, :forbidden}
  end

  @doc "Verify a new job without consuming its nonce; the sidecar enqueues over the scoped socket."
  def prepare(params) do
    with {:ok, _offer, public, input} <- prove(params, "POST"),
         :ok <- authorize(params["biscuit"], public, params["resource"]),
         true <- Occupancy.accepted_design?(params["design_id"]) do
      frame = %{
        "biscuit_digest" => hex(Biscuit.blake3_hash(Base.decode64!(params["biscuit"]))),
        "audience" => params["audience"],
        "resource" => params["resource"],
        "design_id" => params["design_id"],
        "input_blake3" => hex(Biscuit.blake3_hash(input)),
        "idempotency_key" => params["idempotency_key"],
        "holder_fp" => hex(Biscuit.holder_fingerprint(public)),
        "member_pk" => params["member_pk"],
        "proof" => params
      }

      {:ok, %{nonce: params["nonce"], frame: frame}}
    else
      _ -> {:error, :forbidden}
    end
  rescue
    _ -> {:error, :forbidden}
  end

  @doc false
  def enqueue(params, pending \\ Pending) do
    with {:ok, %{nonce: nonce, frame: frame}} <- prepare(params),
         {:ok, id} <- Pending.enqueue(pending, nonce, frame) do
      {:ok, %{pending_id: id, resource: frame["resource"], job_digest: Pending.job_digest(frame)}}
    end
  end

  @doc "Revalidate under the sidecar's occupancy lock, before scoped admission."
  def check(params, pending \\ Pending) do
    proof = params["proof"]

    with true <- is_map(proof),
         {:ok, offer, public, input} <- prove(proof, "POST"),
         :ok <- authorize(proof["biscuit"], public, proof["resource"]),
         {:ok, row} <- Pending.fetch(pending, params["pending_id"]),
         true <- row.frame["proof"] == proof,
         true <-
           row.status == :pending or
             (row.status == :dispatched and row.attempt_id == params["attempt_id"]),
         true <-
           System.monotonic_time(:millisecond) - row.enqueue_mono_ms <=
             Application.get_env(:mjolnir, :aie_max_queue_age_ms, 60_000),
         :ok <-
           Guild.admit(%{
             offer: offer,
             holder_fp: Biscuit.holder_fingerprint(public),
             pending_id: params["pending_id"],
             attempt_id: params["attempt_id"],
             pending: pending,
             biscuit_ok: true
           }) do
      {:ok,
       %{
         resource: row.frame["resource"],
         job_digest: row.job_digest,
         wall_ms: offer.max_wall_time * 1000,
         input: :binary.bin_to_list(input)
       }}
    else
      _ -> {:error, :forbidden}
    end
  rescue
    _ -> {:error, :forbidden}
  end

  def signing_message(p) do
    input = Base.decode64!(p["input_b64"] || "")

    domain =
      if p["method"] == "MINT", do: "mjolnir/aie-mint/v1\0", else: "mjolnir/aie-execute/v1\0"

    fields = [
      p["biscuit"] || "",
      p["nonce"],
      p["audience"],
      p["method"],
      p["resource"],
      Biscuit.blake3_hash(input),
      p["design_id"] || "",
      p["idempotency_key"],
      p["holder_public_key"] || "",
      p["member_pk"] || ""
    ]

    IO.iodata_to_binary([domain | Enum.map(fields, &<<byte_size(&1)::32, &1::binary>>)])
  end

  defp prove(p, method) when is_map(p) do
    with true <- p["method"] == method and p["audience"] == audience(),
         true <-
           Enum.all?(["nonce", "resource", "idempotency_key"], fn k ->
             is_binary(p[k]) and byte_size(p[k]) in 1..1024
           end),
         [owner, id, incarnation] <- String.split(p["resource"], "/"),
         :ok <- Offer.authorize_execute(owner, id, incarnation),
         {:ok, offer, _} <- Offer.fetch(owner, id),
         :ok <- being_live(offer),
         true <- method == "MINT" or p["design_id"] in offer.design_ids,
         true <- is_integer(offer.max_wall_time) and offer.max_wall_time > 0,
         {:ok, public} <- decode(p["public_key"], 32),
         {:ok, signature} <- decode(p["signature"], 64),
         encoded = p["input_b64"] || "",
         true <- is_binary(encoded) and byte_size(encoded) <= 1_398_104,
         {:ok, input} <- Base.decode64(encoded),
         true <- byte_size(input) <= @max_input,
         true <- :crypto.verify(:eddsa, :none, signing_message(p), signature, [public, :ed25519]) do
      {:ok, offer, public, input}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp mint_grant(p, offer, public) do
    cond do
      public == offer.being_pubkey -> :ok
      p["holder_public_key"] == p["public_key"] -> authorize(p["biscuit"], public, p["resource"])
      true -> {:error, :forbidden}
    end
  end

  defp authorize(b64, public, resource) do
    with {:ok, biscuit} <- decode(b64),
         hex_key = Biscuit.authority().public_hex,
         fp = hex(Biscuit.holder_fingerprint(public)),
         {:error, _} <- Biscuit.authorize(biscuit, hex_key, fp, resource, "aie-execute", false),
         :ok <- Biscuit.authorize(biscuit, hex_key, fp, resource, "aie-execute", true) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp being_live(offer) do
    case Mjolnir.VM.get(offer.vm_id) do
      {:ok, %{state: :running}} ->
        :ok

      _ ->
        case Mjolnir.DormantRegistry.lookup(offer.vm_id) do
          {:ok, %{snapshot_name: name}} when is_binary(name) and name != "" ->
            root = Application.fetch_env!(:mjolnir, :btrfs_root)

            if File.dir?(Path.join([root, "@snapshots", name])),
              do: :ok,
              else: {:error, :missing_being}

          _ ->
            {:error, :missing_being}
        end
    end
  end

  defp consume(nonce), do: if(Nonces.consume(nonce) == :ok, do: :ok, else: {:error, :nonce})
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)

  defp decode(value, size) do
    with {:ok, bytes} <- decode(value), true <- byte_size(bytes) == size do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp decode(value) when is_binary(value), do: Base.decode64(value)
  defp decode(_), do: :error
end
