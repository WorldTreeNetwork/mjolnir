defmodule Mjolnir.Forge.Diff do
  @moduledoc """
  Three-way diff matrix: given what's declared, what we previously owned, and
  what's currently observed, classify each resource into a status that
  determines the reconciler's next action.

  | declared | owned | observed | status       | action                  |
  |----------|-------|----------|--------------|-------------------------|
  | ✓        | ✓     | matches  | :converged   | none                    |
  | ✓        | ✓     | differs  | :drifted     | re-apply                |
  | ✓        | ✓     | missing  | :missing     | re-apply (recreate)     |
  | ✓        | ✗     | ✗        | :new         | create                  |
  | ✓        | ✗     | matches  | :converged   | adopt (exact match)     |
  | ✓        | ✗     | differs  | :conflict    | human ack required      |
  | ✗        | ✓     | ✓        | :prune       | delete                  |
  | ✗        | ✓     | ✗        | :tombstone   | clear ownership row     |
  | ✗        | ✗     | ✓        | :unmanaged   | adopt / ignore / delete |

  This module is a pure function — no I/O, no DB. Callers build the three
  input maps from `Declarations.for_host/1`, `Store.list_owned/1`, and a
  sequence of `Resource.observe/3` calls, then pass them here.

  Each input map is keyed by `{kind_module, id}` and carries:

    * declared: `{module, id} => content`
    * owned: `{module, id} => owned_hash`
    * observed: `{module, id} => {:present, content} | :missing`

  Output entries carry the declared content (for apply) and observed content
  (for diff display) so downstream code doesn't have to re-observe.
  """

  @type key :: {module(), String.t()}
  @type status ::
          :converged
          | :drifted
          | :missing
          | :new
          | :conflict
          | :prune
          | :tombstone
          | :unmanaged

  @type entry :: %{
          kind: module(),
          id: String.t(),
          status: status(),
          declared_content: term() | nil,
          observed_content: term() | nil,
          declared_hash: binary() | nil,
          owned_hash: binary() | nil,
          observed_hash: binary() | nil
        }

  alias Mjolnir.Forge.Canonical

  @spec compute(map(), map(), map()) :: [entry()]
  def compute(declared, owned, observed) do
    keys =
      MapSet.new()
      |> union_keys(declared)
      |> union_keys(owned)
      |> union_keys(observed)

    keys
    |> Enum.sort()
    |> Enum.map(&classify(&1, declared, owned, observed))
  end

  defp union_keys(set, map), do: Enum.reduce(Map.keys(map), set, &MapSet.put(&2, &1))

  defp classify({kind, id} = key, declared, owned, observed) do
    decl = Map.get(declared, key)
    own = Map.get(owned, key)
    obs = Map.get(observed, key)

    decl_hash = decl && content_hash(kind, decl)
    obs_hash = observed_hash(kind, obs)

    status = status_for(decl, decl_hash, own, obs, obs_hash)

    %{
      kind: kind,
      id: id,
      status: status,
      declared_content: decl,
      observed_content: observed_content(obs),
      declared_hash: decl_hash,
      owned_hash: own,
      observed_hash: obs_hash
    }
  end

  # Resolve status per the matrix. The branching here IS the design spec —
  # keep it readable and exhaustive rather than clever.
  defp status_for(_decl = nil, _, _own = nil, _obs = nil, _), do: :tombstone

  defp status_for(_decl = nil, _, _own = nil, obs, _) when not is_nil(obs) and obs != :missing,
    do: :unmanaged

  defp status_for(_decl = nil, _, _own, :missing, _), do: :tombstone
  defp status_for(_decl = nil, _, _own, nil, _), do: :tombstone

  defp status_for(_decl = nil, _, own, obs, _)
       when not is_nil(own) and not is_nil(obs) and obs != :missing,
       do: :prune

  defp status_for(decl, _decl_hash, _own = nil, _obs = nil, _) when not is_nil(decl), do: :new

  defp status_for(decl, _decl_hash, _own = nil, :missing, _) when not is_nil(decl), do: :new

  defp status_for(decl, decl_hash, _own = nil, _obs, obs_hash)
       when not is_nil(decl) and not is_nil(obs_hash) do
    # Adopt-on-exact-match: take ownership silently when content already matches.
    if decl_hash == obs_hash, do: :converged, else: :conflict
  end

  defp status_for(decl, _decl_hash, _own, :missing, _) when not is_nil(decl), do: :missing
  defp status_for(decl, _decl_hash, _own, nil, _) when not is_nil(decl), do: :missing

  defp status_for(decl, decl_hash, _own, _obs, obs_hash)
       when not is_nil(decl) and not is_nil(obs_hash) do
    if decl_hash == obs_hash, do: :converged, else: :drifted
  end

  defp status_for(_, _, _, _, _), do: :tombstone

  defp content_hash(kind, content), do: kind.canonical(content) |> Canonical.hash_bytes()
  defp observed_hash(_kind, nil), do: nil
  defp observed_hash(_kind, :missing), do: nil
  defp observed_hash(kind, {:present, content}), do: content_hash(kind, content)
  # If observe fails (e.g. transport error), defensively treat as not observed.
  defp observed_hash(_kind, {:error, _}), do: nil

  defp observed_content({:present, content}), do: content
  defp observed_content(_), do: nil
end
