defmodule Mjolnir.GuestFence.Store do
  @moduledoc """
  Single-writer, checksummed, synchronous host journal.

  Every frame is a complete state. Recovery rejects even a partial trailing
  frame: uncertain storage never silently rolls ownership back. The directory
  must be on host storage and have exactly one host writer across OS processes.
  Host also prevents two writers to the same directory within this BEAM.
  """
  @magic "MJGF1"
  @max_frame 128 * 1024 * 1024

  def open(directory) do
    with :ok <- File.mkdir_p(directory),
         path = Path.join(directory, "host.journal"),
         :ok <- check_manifest(path, directory),
         :ok <- create(path, directory),
         {:ok, bytes} <- File.read(path),
         {:ok, state} <- recover(bytes, nil),
         {:ok, file} <- :file.open(String.to_charlist(path), [:raw, :binary, :append]) do
      {:ok, %{file: file}, state}
    end
  end

  # A retained marker distinguishes a lost journal from an uninitialized store.
  # Both entries are synced before the first ownership result can be exposed.
  defp check_manifest(path, directory) do
    marker = Path.join(directory, "host.initialized")

    case {File.exists?(marker), File.exists?(path)} do
      {true, false} ->
        {:error, :uncertain_store}

      {true, true} ->
        :ok

      {false, _} ->
        case File.open(marker, [:write, :binary, :exclusive]) do
          {:ok, file} ->
            result = with :ok <- IO.binwrite(file, @magic), do: :file.sync(file)
            File.close(file)
            result

          error ->
            error
        end
    end
  end

  defp create(path, directory) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        result = with :ok <- IO.binwrite(file, @magic), do: :file.sync(file)
        File.close(file)
        # fsync of the file alone does not persist a newly created directory entry.
        with :ok <- result do
          case System.cmd("sync", ["-f", directory], stderr_to_stdout: true) do
            {_, 0} -> :ok
            _ -> {:error, :directory_sync_failed}
          end
        end

      {:error, :eexist} ->
        :ok

      error ->
        error
    end
  end

  def append(store, state) do
    payload = :erlang.term_to_binary(state)

    if byte_size(payload) <= @max_frame do
      checksum = :crypto.hash(:sha256, payload)
      frame = <<byte_size(payload)::unsigned-big-64, checksum::binary, payload::binary>>
      with :ok <- :file.write(store.file, frame), do: :file.sync(store.file)
    else
      {:error, :store_capacity}
    end
  end

  def close(store), do: :file.close(store.file)

  defp recover(@magic <> rest, nil), do: frames(rest, nil)
  defp recover(_, _), do: {:error, :uncertain_store}
  defp frames(<<>>, state), do: {:ok, state}

  defp frames(<<size::unsigned-big-64, checksum::binary-size(32), rest::binary>>, _state)
       when size <= @max_frame and byte_size(rest) >= size do
    <<payload::binary-size(^size), tail::binary>> = rest

    if :crypto.hash(:sha256, payload) == checksum do
      try do
        frames(tail, :erlang.binary_to_term(payload, [:safe]))
      rescue
        _ -> {:error, :uncertain_store}
      end
    else
      {:error, :uncertain_store}
    end
  end

  defp frames(_, _), do: {:error, :uncertain_store}
end
