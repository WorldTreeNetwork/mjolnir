defmodule Mjolnir.Entropy do
  @moduledoc """
  Forces a guest CRNG reseed after a memory-snapshot restore, and gates the VM
  until it succeeds.

  ## The vulnerability

  Restoring one memory snapshot twice produces two guests whose kernel CRNG is
  in *identical* state. They then generate the same session keys, the same TLS
  nonces, the same UUIDs. This is the classic VM-snapshot cloning
  vulnerability — a real key-compromise path, not a theoretical one.

  Note the asymmetry, because it decides how much this matters: thawing a
  snapshot once and discarding it is mildly exposed. **Forking N VMs from one
  memory image** — which is a feature the freeze/thaw work exists to enable —
  hands every fork the same random stream. The mitigation therefore has to run
  on *every* restore, including the first, since "first" is not distinguishable
  from "one of N" after the fact.

  ## Why not just add a virtio-rng device

  A virtio-rng device (added in `Mjolnir.CloudHypervisor.Config.rng_config/1`)
  gives the guest a *source* of host entropy. It does not make the guest *use*
  it at any particular moment. A restored guest resumes with a seeded-looking
  CRNG and no reason to poll the device, so it can emit duplicate key material
  long before the driver next contributes. The device is a prerequisite, not
  the fix.

  ## Why not VMGENID

  VMGENID *is* the correct mechanism: an ACPI device holding a 128-bit
  generation ID that the hypervisor changes on restore, which Linux's
  `drivers/virt/vmgenid.c` (5.18+) notices and acts on by reseeding the CRNG
  **inside the kernel, before userspace is scheduled**. Nothing in userspace
  can match that ordering guarantee.

  Neither half exists on this stack yet: our PVH kernel is built without
  `CONFIG_VMGENID`, and Cloud Hypervisor does not emit the device. That is
  tracked as `mjolnir-3y6.13` and it is the real fix.

  ## What this module does instead, and its honest limit

  1. Draw fresh bytes from the host CSPRNG (`:crypto.strong_rand_bytes/1`).
  2. Hand them to the guest agent, which mixes **and credits** them via the
     `RNDADDENTROPY` ioctl — not a write to `/dev/urandom`, which mixes without
     crediting and so does not move the kernel's entropy estimate.
  3. Refuse to expose the VM until the guest confirms.

  Step 3 is what makes the residual race tolerable. vCPUs resume all at once,
  so the agent cannot beat every other userspace process in the guest to the
  first random byte — that race is unavoidable without VMGENID and this module
  does not pretend otherwise. What it does guarantee is that **no outside
  caller can induce** the use of duplicate randomness: no PTY, no ticket, no
  network exposure is published until the reseed is confirmed. The exposure is
  narrowed to processes already running inside the guest.

  ## Failure direction

  `reseed/2` failing means the VM stays unreachable. That is deliberate: an
  unreachable VM is an operational problem, a silently-cloned CRNG is a key
  compromise. Fail closed.
  """

  require Logger

  alias Mjolnir.Vsock.Connection

  # 32 bytes = 256 bits, the standard full-strength CRNG seed. The guest credits
  # 8 bits per byte, so this claims a full reseed — justified, because the bytes
  # come from the host's already-seeded CSPRNG.
  @seed_bytes 32

  @default_timeout_ms 10_000

  @doc """
  Draw a fresh seed from the host CSPRNG.

  Separate from `reseed/2` so callers can log or audit the fact that a seed was
  drawn without the value ever being returned to them.
  """
  @spec fresh_seed() :: binary()
  def fresh_seed, do: :crypto.strong_rand_bytes(@seed_bytes)

  @doc """
  Build the `reseed_entropy` request for a given seed.

  Hex rather than base64 keeps the payload inside the existing JSON control
  channel without adding an encoder on the guest side, where every dependency
  is paid for in the static musl binary injected into every rootfs.
  """
  @spec request(binary(), String.t()) :: map()
  def request(seed, id \\ nil) do
    %{
      "type" => "reseed_entropy",
      "id" => id || UUID.uuid4(),
      "seed_hex" => Base.encode16(seed, case: :lower)
    }
  end

  @doc """
  Reseed a guest's CRNG over an established vsock connection.

  Returns `:ok` only when the guest confirms it both mixed **and credited** the
  bytes. Every other outcome — a refusal, an old agent that does not know the
  request, a timeout — is an error, and callers must treat it as "do not expose
  this VM".

  ## Options

    - `:timeout_ms` — how long to wait for confirmation (default
      #{@default_timeout_ms})
    - `:seed` — supply the seed (tests only; production always draws fresh)
  """
  @spec reseed(pid(), keyword()) :: :ok | {:error, term()}
  def reseed(conn, opts \\ []) do
    seed = Keyword.get_lazy(opts, :seed, &fresh_seed/0)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case Connection.send_request(conn, request(seed), timeout) do
      {:ok, response} -> interpret(response)
      {:error, reason} -> {:error, {:reseed_transport_failed, reason}}
    end
  end

  @doc """
  Classify a guest's `reseed_entropy_response`.

  Split out and public so the fail-closed policy is testable without a live
  guest — this is the function that decides whether a restored VM may be
  exposed, so it is worth pinning down exactly.
  """
  @spec interpret(map()) :: :ok | {:error, term()}
  def interpret(%{"type" => "reseed_entropy_response", "ok" => true, "bytes" => bytes})
      when is_integer(bytes) and bytes > 0 do
    Logger.info("Guest CRNG reseeded with #{bytes} bytes")
    :ok
  end

  def interpret(%{"type" => "reseed_entropy_response", "ok" => true, "bytes" => bytes}) do
    # ok: true with no bytes credited is a guest bug, and trusting it would
    # defeat the entire gate. Refuse.
    {:error, {:reseed_credited_nothing, bytes}}
  end

  def interpret(%{"type" => "reseed_entropy_response", "ok" => false} = response) do
    {:error, {:reseed_refused, response["error"]}}
  end

  # An agent too old to know `reseed_entropy` answers with the generic error
  # shape rather than timing out (mjolnir-azm). Surfacing it distinctly matters:
  # "your guest agent predates the reseed op" is an operator action, whereas
  # `:reseed_refused` reads as a kernel or permissions problem.
  def interpret(%{"type" => "error", "error" => error}) do
    {:error, {:reseed_unsupported_by_agent, error}}
  end

  def interpret(other), do: {:error, {:reseed_unexpected_response, other}}
end
