defmodule Mjolnir.Unikernel do
  @moduledoc """
  Guest kind `unikernel`: a Reflect ELF with no rootfs and no agent.

  The host BEAM opens QUIC. `mj` only calls the API. The command line is
  exactly four `reflect.*` words. One vCPU, 512 MiB.

  ## Entity keys

  A guest runs for an entity. Its key is a 32-byte Ed25519 seed that the
  entity's owner supplies at spawn (`entity_key`, base58) and keeps. Mjolnir
  never makes one for a guest. The key reaches the guest as the file Cloud
  Hypervisor gives at boot (`initramfs`): `<socket_dir>/<vm_id>.entity-key`,
  mode 0600, removed once the guest is ready or the boot fails. The key is
  held in memory as a closure (`entity_key_fun/1`) so that an `inspect` of
  spawn options or state does not print it, and it is never stored or
  returned. What is kept is the guest's name (`entity`), Blake3 of the dCBOR
  of its public key, as base58 (homoiconic `unikernel/entity.zig`).

  The host's BEAM has one key of its own as a QUIC client
  (`:reflect_client_key`, default `<state_dir>/reflect-client.key`). Its name
  is the first name in the guest's `reflect.allow`. The caller's `allow`
  list (at most 7 names) follows it.
  """

  @budget_default 100_000_000
  @budget_max 100_000_000
  @program_max 1176
  @boot_deadline_ms 90_000
  @allow_max 7

  def boot_deadline_ms, do: @boot_deadline_ms
  def program_max, do: @program_max

  def prepare_spawn(opts) when is_list(opts), do: prepare_spawn(Map.new(opts))

  def prepare_spawn(opts) when is_map(opts) do
    kind = normalize_kind(Map.get(opts, :kind) || Map.get(opts, "kind"))

    if kind == :linux do
      {:ok, opts |> drop_key_fields() |> Map.delete(:allow) |> Map.put(:kind, :linux)}
    else
      prepare_unikernel(opts)
    end
  end

  @doc """
  The guest's command line: exactly four words. `allow` is the list of names
  the guest finishes a handshake with, Mjolnir's client name first.
  """
  def cmdline(guest_ip, udp_port, quic_port, [_ | _] = allow)
      when is_binary(guest_ip) and is_integer(udp_port) and is_integer(quic_port) do
    "reflect.ip=#{guest_ip} reflect.port=#{udp_port} reflect.quic_port=#{quic_port} " <>
      "reflect.allow=#{Enum.join(Enum.uniq(allow), ",")}"
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

  @key_refusals [
    "reflect: no entity key",
    "reflect: the entity key is not 32 bytes",
    "reflect: the entity key is all zero",
    "reflect: the entity key is not usable"
  ]

  @doc """
  The boot outcome a serial log shows, given the name the guest must print.

  `:ok` when the guest printed `reflect: entity <expected>` and its QUIC
  line; `{:error, :entity_name_mismatch}` when it printed another name;
  `{:error, :entity_key_refused}` when it refused its key file;
  `{:error, :reflect_config_refused}` when it refused its command line;
  `:wait` otherwise.
  """
  def boot_outcome(log, quic_port, expected) when is_binary(log) and is_binary(expected) do
    names = Regex.scan(~r/^reflect: entity (\S+)\s*$/m, log, capture: :all_but_first)

    cond do
      Enum.any?(@key_refusals, &String.contains?(log, &1)) ->
        {:error, :entity_key_refused}

      String.contains?(log, "reflect: the network address is not valid") ->
        {:error, :reflect_config_refused}

      Enum.any?(names, fn [name] -> name != expected end) ->
        {:error, :entity_name_mismatch}

      names != [] and ready_line?(log, quic_port) ->
        :ok

      ready_line?(log, quic_port) ->
        # Ready with no entity line: an image built before homoiconic e9a4c86.
        {:error, :entity_name_mismatch}

      true ->
        :wait
    end
  end

  # ── Entity keys and names ─────────────────────────────────────────

  @doc "The 32 bytes of a key given as base58 text, or `:error`."
  def parse_key(text) when is_binary(text) do
    with {:ok, bytes} <- Mjolnir.Base58.decode(text, 32),
         true <- Mjolnir.Base58.encode(bytes) == text,
         false <- bytes == <<0::256>> do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  def parse_key(_), do: :error

  @doc "A name in canonical base58 text (32 bytes), or `:error`."
  def parse_name(text) when is_binary(text) do
    with {:ok, bytes} <- Mjolnir.Base58.decode(text, 32),
         true <- Mjolnir.Base58.encode(bytes) == text do
      {:ok, text}
    else
      _ -> :error
    end
  end

  def parse_name(_), do: :error

  @doc "Up to #{@allow_max} names, none twice. `nil` is the empty list."
  def parse_allow(nil), do: {:ok, []}

  def parse_allow(list) when is_list(list) and length(list) <= @allow_max do
    names = Enum.map(list, &parse_name/1)

    cond do
      Enum.any?(names, &(&1 == :error)) -> :error
      length(Enum.uniq(list)) != length(list) -> :error
      true -> {:ok, list}
    end
  end

  def parse_allow(_), do: :error

  def allow_max, do: @allow_max

  @doc """
  The key bytes held by spawn options. The key travels as a zero-arity
  function so `inspect` of the options shows `#Function<...>`, not the key.
  """
  def entity_key_fun(bytes) when is_binary(bytes) and byte_size(bytes) == 32,
    do: fn -> bytes end

  @doc "Path of the entity key file for a VM's boot."
  def key_file_path(socket_dir, vm_id), do: Path.join(socket_dir, "#{vm_id}.entity-key")

  @doc """
  Write `bytes` to `path` so that no other user can ever read them.

  Elixir cannot create a file with a mode. So the file is created empty in a
  fresh directory of mode 0700, set to 0600 before any byte is written, and
  then hard-linked to `path` (which fails if `path` exists) and unlinked from
  the directory. Its bytes are never in a file another user can open.
  """
  def write_private(path, bytes) when is_binary(path) and is_binary(bytes) do
    dir = Path.join(Path.dirname(path), ".private-#{Base.encode16(:crypto.strong_rand_bytes(8))}")
    tmp = Path.join(dir, "key")

    try do
      with :ok <- File.mkdir(dir),
           :ok <- File.chmod(dir, 0o700),
           :ok <- File.write(tmp, "", [:exclusive]),
           :ok <- File.chmod(tmp, 0o600),
           :ok <- File.write(tmp, bytes, [:append]),
           :ok <- :file.make_link(tmp, path) do
        :ok
      end
    after
      _ = File.rm(tmp)
      _ = File.rmdir(dir)
    end
  end

  @doc """
  Path of this host's QUIC client key, created (0600, 32 random bytes) when
  it does not exist. `{:error, :reflect_client_key_invalid}` when it exists
  and is not 32 bytes, or is all zero.
  """
  def client_key do
    path = client_key_path()

    case File.read(path) do
      {:ok, <<0::256>>} ->
        {:error, :reflect_client_key_invalid}

      {:ok, bytes} when byte_size(bytes) == 32 ->
        {:ok, path}

      {:ok, _} ->
        {:error, :reflect_client_key_invalid}

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(Path.dirname(path)) do
          case write_private(path, :crypto.strong_rand_bytes(32)) do
            :ok -> {:ok, path}
            # Another boot made it first.
            {:error, :eexist} -> client_key()
            {:error, reason} -> {:error, {:reflect_client_key, reason}}
          end
        end

      {:error, reason} ->
        {:error, {:reflect_client_key, reason}}
    end
  end

  @doc """
  Before a unikernel's process starts: this host's client key exists and
  its name can be computed. A boot that fails this early would end before
  its caller is waiting, and the caller would see an exit, not the reason.
  """
  def preflight(%{kind: :unikernel}) do
    with {:ok, path} <- client_key(),
         {:ok, _name} <- entity_name(path) do
      :ok
    end
  end

  def preflight(_opts), do: :ok

  def client_key_path do
    Application.get_env(:mjolnir, :reflect_client_key) ||
      Path.join(Application.fetch_env!(:mjolnir, :state_dir), "reflect-client.key")
  end

  @doc """
  The name of the entity whose key is the 32-byte file at `path`, from
  `priv/reflect-entity name <path>` (`:reflect_entity`). Tests replace it
  with `:unikernel_entity_name`, a function of the path.
  """
  def entity_name(path) when is_binary(path) do
    result =
      case Application.get_env(:mjolnir, :unikernel_entity_name) do
        fun when is_function(fun, 1) -> fun.(path)
        _ -> run_entity_tool(path)
      end

    case result do
      {:ok, name} ->
        case parse_name(name) do
          {:ok, name} -> {:ok, name}
          :error -> {:error, :entity_name_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_entity_tool(path) do
    bin = Application.get_env(:mjolnir, :reflect_entity) || entity_tool_default()

    if File.exists?(bin) do
      case System.cmd(bin, ["name", path], stderr_to_stdout: true) do
        {out, 0} -> {:ok, String.trim(out)}
        _ -> {:error, :entity_name_failed}
      end
    else
      {:error, :reflect_entity_missing}
    end
  end

  defp entity_tool_default, do: Path.join(:code.priv_dir(:mjolnir), "reflect-entity")

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
    key = Map.get(opts, :entity_key) || Map.get(opts, "entity_key")
    allow = Map.get(opts, :allow, Map.get(opts, "allow"))

    cond do
      Map.get(opts, :snapshot) || Map.get(opts, "snapshot") ->
        {:error, :unikernel_unsupported}

      memory not in [nil, 512, "512"] ->
        {:error, :unikernel_memory}

      not is_binary(kernel) ->
        {:error, :kernel_required}

      not kernel_allowed?(kernel) ->
        {:error, :kernel_not_allowed}

      key in [nil, ""] ->
        {:error, :entity_key_required}

      not is_function(key, 0) and parse_key(key) == :error ->
        {:error, :entity_key_invalid}

      parse_allow(allow) == :error ->
        {:error, :allow_invalid}

      true ->
        {:ok, allow} = parse_allow(allow)

        {:ok,
         opts
         |> drop_key_fields()
         |> Map.put(:kind, :unikernel)
         |> Map.put(:kernel, Path.expand(kernel))
         |> Map.put(:entity_key, wrap_key(key))
         |> Map.put(:allow, allow)
         |> Map.put(:memory_mb, 512)
         |> Map.put(:vcpus, 1)
         |> Map.put(:restart_policy, :never)
         |> Map.delete(:base_image)
         |> Map.delete("base_image")}
    end
  end

  defp wrap_key(fun) when is_function(fun, 0), do: fun

  defp wrap_key(text) do
    {:ok, bytes} = parse_key(text)
    entity_key_fun(bytes)
  end

  # The key text, and any older pin, never travel further than here.
  defp drop_key_fields(opts) do
    Map.drop(opts, [:entity_key, "entity_key", "allow", :peer_pin, "peer_pin"])
  end

  defp normalize_kind(:unikernel), do: :unikernel
  defp normalize_kind("unikernel"), do: :unikernel
  defp normalize_kind(_), do: :linux
end
