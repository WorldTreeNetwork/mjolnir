defmodule Mjolnir.Unikernel.Exchange do
  @moduledoc """
  One QUIC exchange against a Reflect guest, run by the host BEAM.

  The socket is opened by `native/reflect_quic/host.zig`, which this
  process starts and waits on. `mj` never calls it.
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

    if not File.exists?(bin) do
      {:error, :reflect_client_missing}
    else
      program = job.program

      path =
        Path.join(System.tmp_dir!(), "reflect-#{Base.encode16(:crypto.strong_rand_bytes(8))}")

      try do
        File.write!(path, program)

        {out, status} =
          System.cmd(
            bin,
            [
              job.guest_ip,
              Integer.to_string(job.quic_port),
              Integer.to_string(job.budget),
              job.peer_pin,
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
  end

  defp map_status(0, out), do: {:ok, 0, out}
  defp map_status(5, _out), do: {:ok, 2, ""}
  defp map_status(6, _out), do: {:ok, 3, ""}
  defp map_status(3, _out), do: {:error, :peer_key_refused}
  defp map_status(_, _), do: {:error, :unikernel_timeout}

  defp default_bin do
    Path.join(:code.priv_dir(:mjolnir), "reflect-quic-client")
  end

  def timeout_ms, do: @timeout_ms
end
