defmodule Mjolnir.Unikernel do
  @moduledoc """
  Guest kind `unikernel`: a Reflect ELF with no rootfs and no agent.

  The host BEAM opens QUIC. `mj` only calls the API. The command line is
  exactly three `reflect.*` words. One vCPU, 512 MiB.
  """

  @budget_default 100_000_000
  @budget_max 100_000_000
  @program_max 1176
  @boot_deadline_ms 90_000

  def boot_deadline_ms, do: @boot_deadline_ms
  def program_max, do: @program_max

  def prepare_spawn(opts) when is_list(opts), do: prepare_spawn(Map.new(opts))

  def prepare_spawn(opts) when is_map(opts) do
    kind = normalize_kind(Map.get(opts, :kind) || Map.get(opts, "kind"))

    if kind == :linux do
      {:ok, Map.put(opts, :kind, :linux)}
    else
      prepare_unikernel(opts)
    end
  end

  def cmdline(guest_ip, udp_port, quic_port)
      when is_binary(guest_ip) and is_integer(udp_port) and is_integer(quic_port) do
    "reflect.ip=#{guest_ip} reflect.port=#{udp_port} reflect.quic_port=#{quic_port}"
  end

  def ports(vm_id) when is_binary(vm_id) do
    n = :erlang.phash2(vm_id, 10_000)
    {20_000 + n, 30_000 + n}
  end

  def normalize_budget(nil), do: {:ok, @budget_default}

  def normalize_budget(n) when is_integer(n) and n >= 1 and n <= @budget_max, do: {:ok, n}

  def normalize_budget(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> normalize_budget(i)
      _ -> {:error, :invalid_budget}
    end
  end

  def normalize_budget(_), do: {:error, :invalid_budget}

  def check_program(bytes) when is_binary(bytes) and byte_size(bytes) <= @program_max, do: :ok
  def check_program(bytes) when is_binary(bytes), do: {:error, :program_too_large}
  def check_program(_), do: {:error, :program_too_large}

  @doc """
  A caller id becomes the 8-byte RFL1 correlation id.

  Sixteen hex digits are that id. Any other string is the first 8 bytes
  of SHA-256 of the UTF-8 string. `nil` is a random id.
  """
  def correlation_id(nil), do: :crypto.strong_rand_bytes(8)

  def correlation_id(id) when is_binary(id) do
    if byte_size(id) == 16 and String.match?(id, ~r/^[0-9a-fA-F]+$/) do
      Base.decode16!(id, case: :mixed)
    else
      :crypto.hash(:sha256, id) |> binary_part(0, 8)
    end
  end

  def kernel_allowed?(path) when is_binary(path) do
    prefixes = Application.get_env(:mjolnir, :unikernel_kernel_prefixes, [])
    expanded = Path.expand(path)

    Enum.any?(prefixes, fn prefix ->
      root = Path.expand(prefix)
      expanded == root or String.starts_with?(expanded, root <> "/")
    end)
  end

  def kernel_allowed?(_), do: false

  def ready_line?(log, quic_port) when is_binary(log) and is_integer(quic_port) do
    String.contains?(log, "reflect: quic #{quic_port}")
  end

  def decode_reply(frame) when is_binary(frame) and byte_size(frame) >= 24 do
    <<"RFL1", kind, status, _reserved::16, _id::64, _budget::64, payload::binary>> = frame

    if kind == 1 do
      {:ok, status, payload}
    else
      {:error, :unikernel_timeout}
    end
  end

  def decode_reply(_), do: {:error, :unikernel_timeout}

  defp prepare_unikernel(opts) do
    memory = Map.get(opts, :memory_mb) || Map.get(opts, "memory_mb")
    kernel = Map.get(opts, :kernel) || Map.get(opts, "kernel")
    pin = Map.get(opts, :peer_pin) || Map.get(opts, "peer_pin")

    cond do
      Map.get(opts, :snapshot) || Map.get(opts, "snapshot") ->
        {:error, :unikernel_unsupported}

      memory not in [nil, 512, "512"] ->
        {:error, :unikernel_memory}

      not is_binary(kernel) ->
        {:error, :kernel_required}

      not kernel_allowed?(kernel) ->
        {:error, :kernel_not_allowed}

      not valid_pin?(pin) ->
        {:error, :peer_pin_required}

      true ->
        {:ok,
         opts
         |> Map.put(:kind, :unikernel)
         |> Map.put(:kernel, Path.expand(kernel))
         |> Map.put(:peer_pin, String.downcase(pin))
         |> Map.put(:memory_mb, 512)
         |> Map.put(:vcpus, 1)
         |> Map.put(:restart_policy, :never)
         |> Map.delete(:base_image)
         |> Map.delete("base_image")}
    end
  end

  defp valid_pin?(pin) when is_binary(pin) do
    byte_size(pin) == 64 and String.match?(pin, ~r/^[0-9a-fA-F]+$/)
  end

  defp valid_pin?(_), do: false

  defp normalize_kind(:unikernel), do: :unikernel
  defp normalize_kind("unikernel"), do: :unikernel
  defp normalize_kind(_), do: :linux
end
