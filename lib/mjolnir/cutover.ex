defmodule Mjolnir.Cutover do
  @moduledoc """
  Load the on-disk release into the node that is already running.

  Every beam in the release ebin is loaded. A partial load is not a cutover:
  if one beam cannot be loaded, this raises and the caller must not restart
  the node. This does not hard-purge modules. VM processes keep the code they
  are already running, so hypervisor Ports stay up. Fully qualified calls see
  the new beams.
  """

  @spec apply(Path.t()) :: String.t()
  def apply(ebin) when is_binary(ebin) do
    beams =
      ebin
      |> Path.join("*.beam")
      |> Path.wildcard()
      |> Enum.sort()

    if beams == [] do
      raise "cutover refused: #{ebin} has no beams"
    end

    Enum.each(beams, &load_beam!/1)

    unless function_exported?(Mjolnir.Release, :id, 0) do
      raise "cutover refused: Mjolnir.Release.id/0 is not loaded from #{ebin}"
    end

    Mjolnir.Release.id()
  end

  defp load_beam!(path) do
    bin = File.read!(path)
    module = module_from_beam(path)
    filename = String.to_charlist(path)

    case load_binary(module, filename, bin) do
      {:module, mod} ->
        mod

      {:error, reason} ->
        raise "cutover refused to load #{path}: #{inspect(reason)}"
    end
  end

  defp load_binary(module, filename, bin) do
    case :code.load_binary(module, filename, bin) do
      {:module, mod} ->
        {:module, mod}

      {:error, :not_purged} ->
        # soft_purge drops an unused old version. It does not kill a process
        # that is still running that version. If a process is still in it,
        # fail the cutover instead of hard-purging.
        if :code.soft_purge(module) do
          :code.load_binary(module, filename, bin)
        else
          {:error, :not_purged}
        end

      other ->
        other
    end
  end

  defp module_from_beam(path) do
    base = path |> Path.basename() |> String.trim_trailing(".beam")

    if String.starts_with?(base, "Elixir.") do
      base
      |> String.trim_leading("Elixir.")
      |> String.split(".")
      |> Module.concat()
    else
      String.to_atom(base)
    end
  end
end
