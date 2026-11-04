defmodule Mjolnir.Cutover do
  @moduledoc """
  Load the on-disk release into the node that is already running.

  This does not purge modules and does not stop the node. VM processes keep
  the code they are already running, so hypervisor Ports stay up. Fully
  qualified calls (the health route, `Mjolnir.Release.id/0`) see the new beams.
  """

  @spec apply(Path.t()) :: String.t()
  def apply(ebin) when is_binary(ebin) do
    load_beam!(Path.join(ebin, "Elixir.Mjolnir.Release.beam"))

    router = Path.join(ebin, "Elixir.Mjolnir.API.Router.beam")
    if File.regular?(router), do: load_beam!(router)

    Mjolnir.Release.id()
  end

  defp load_beam!(path) do
    {:ok, bin} = File.read(path)

    module =
      path
      |> Path.basename()
      |> String.trim_trailing(".beam")
      |> String.trim_leading("Elixir.")
      |> then(&Module.concat([&1]))

    case :code.load_binary(module, String.to_charlist(path), bin) do
      {:module, mod} ->
        mod

      {:error, reason} ->
        raise "cutover refused to load #{path}: #{inspect(reason)}"
    end
  end
end
