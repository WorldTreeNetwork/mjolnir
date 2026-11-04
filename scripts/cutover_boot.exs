# Evaluated inside the already-running node. `root` is bound by the caller.
# Uses only Elixir that ships with the previous release, then loads the new
# Mjolnir.Cutover beam from disk. Do not systemctl restart from here.
ebin =
  root
  |> Path.join("_build/prod/rel/mjolnir/lib/mjolnir-*/ebin")
  |> Path.wildcard()
  |> Enum.sort()
  |> List.last()

true = is_binary(ebin)
cutover = Path.join(ebin, "Elixir.Mjolnir.Cutover.beam")
{:ok, bin} = File.read(cutover)

{:module, Mjolnir.Cutover} =
  :code.load_binary(Mjolnir.Cutover, String.to_charlist(cutover), bin)

Mjolnir.Cutover.apply(ebin)
