defmodule Mjolnir.Unikernel.Exchange do
  @moduledoc """
  One QUIC exchange against a Reflect guest, run by the host BEAM.

  The socket is opened by `native/reflect_quic/host.zig`, which this
  process starts and waits on. `mj` never calls it.

  The client presents this host's entity key (`job.client_key`, default
  `Mjolnir.Unikernel.client_key/0`) and accepts only a guest whose name is
  `job.entity`. Exit 3 is a guest that presented another name
  (`:peer_key_refused`); exit 7 is a flight given up with no answer, which
  is what a guest that does not allow this key looks like
  (`:unikernel_timeout`).
  """

  @timeout_ms 60_000

  def run(job) when is_map(job) do
    case Application.get_env(:mjolnir, :unikernel_exchange) do
      fun when is_function(fun, 1) -> fun.(job)
      _ -> port(job)
    end
  end

  def port(job) do
    bin = Application.get_env(:mjolnir, :reflect_quic_client) || default_bin()

    with true <- File.exists?(bin) || {:error, :reflect_client_missing},
         true <- is_binary(job[:entity]) || {:error, :entity_required},
         {:ok, key_path} <- job_client_key(job) do
      exchange(bin, key_path, job)
    end
  end

  defp job_client_key(%{client_key: path}) when is_binary(path), do: {:ok, path}
  defp job_client_key(_job), do: Mjolnir.Unikernel.client_key()

  defp exchange(bin, key_path, job) do
    path = Path.join(System.tmp_dir!(), "reflect-#{Base.encode16(:crypto.strong_rand_bytes(8))}")

    try do
      File.write!(path, job.program)

      {out, status} =
        System.cmd(
          bin,
          [
            job.guest_ip,
            Integer.to_string(job.quic_port),
            Integer.to_string(job.budget),
            key_path,
            job.entity,
            path,
            Base.encode16(job.correlation_id)
          ],
          stderr_to_stdout: true
        )

      map_status(status, out)
    after
      File.rm(path)
    end
  end

  defp map_status(0, out), do: {:ok, 0, out}
  defp map_status(5, _out), do: {:ok, 2, ""}
  defp map_status(6, _out), do: {:ok, 3, ""}
  defp map_status(3, _out), do: {:error, :peer_key_refused}
  defp map_status(7, _out), do: {:error, :unikernel_timeout}
  defp map_status(_, _), do: {:error, :unikernel_timeout}

  defp default_bin do
    Path.join(:code.priv_dir(:mjolnir), "reflect-quic-client")
  end

  def timeout_ms, do: @timeout_ms
end
