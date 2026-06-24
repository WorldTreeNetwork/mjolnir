defmodule Mjolnir.Deploy.CacheKey do
  @moduledoc """
  Content-addressed cache key computation for deploy build layers.

  Each build layer's cache key is a stable, lowercase hex SHA-256 derived from
  three components:

  - `parent_layer_id` — the key (or snapshot name) of the parent layer. `nil`
    for the base layer; distinct from `""` (empty string parent ID).
  - `step_command` — the shell command for this build step (e.g. `"npm ci"`).
  - `input_hash` — hash of the step's relevant inputs. For install steps, hash
    the lockfile (`hash_file/1`). For build steps, hash the source tree
    (`hash_tree/2`).

  ## Combination scheme

  Each component is first hashed individually with SHA-256 (producing a
  fixed-length 32-byte digest). `nil` is encoded as the atom literal `"nil"`,
  which is distinct from the empty string `""`. The three 32-byte digests are
  then concatenated in order (parent, command, input) and hashed once more with
  SHA-256. Using fixed-width digests eliminates length-extension and boundary
  ambiguity: `("a", "bc", "d")` and `("ab", "c", "d")` produce different outer
  hashes because the inner SHA-256s of `"a"` and `"ab"` differ, and the
  concatenated digest buffers therefore differ.

  ## File and tree hashing

  `hash_file/1` hashes a single file's raw bytes — suitable for lockfiles
  (`package-lock.json`, `bun.lock`, `pnpm-lock.yaml`).

  `hash_tree/2` hashes a directory tree deterministically: all regular files are
  walked recursively, sorted by relative path (ensuring filesystem-enumeration
  independence), and each file's relative path + contents are folded into a
  running SHA-256. Two trees with identical files, contents, and paths produce
  identical hashes; editing, renaming, adding, or removing any file produces a
  different hash.

  The default exclusions for `hash_tree/2` are `["node_modules", ".git",
  "build", ".svelte-kit"]` — these are build outputs and dependency caches that
  should not participate in the source-tree hash (changing them must not
  invalidate the layer key for the build step itself).
  """

  @default_tree_excludes ["node_modules", ".git", "build", ".svelte-kit"]

  @doc """
  Computes a stable, lowercase hex SHA-256 cache key for a build layer.

  The key is derived from all three components; changing any one of them
  (or swapping the order of `step_command` and `input_hash`) produces a
  different key.

  ## Parameters

  - `parent_layer_id` — ID of the parent snapshot layer, or `nil` for the
    base layer.
  - `step_command` — the shell command for this step.
  - `input_hash` — hash of the step's relevant inputs (lockfile or source tree).

  ## Examples

      iex> Mjolnir.Deploy.CacheKey.compute(nil, "npm ci", "abc123")
      "..."  # 64-char lowercase hex string

      iex> Mjolnir.Deploy.CacheKey.compute("layer-1", "npm run build", "def456")
      "..."  # different key

  """
  @spec compute(
          parent_layer_id :: String.t() | nil,
          step_command :: String.t(),
          input_hash :: String.t()
        ) :: String.t()
  def compute(parent_layer_id, step_command, input_hash) do
    parent_bytes = hash_component(parent_layer_id)
    command_bytes = hash_component(step_command)
    input_bytes = hash_component(input_hash)

    :crypto.hash(:sha256, parent_bytes <> command_bytes <> input_bytes)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Returns a lowercase hex SHA-256 hash of a single file's contents.

  Suitable for hashing lockfiles (`package-lock.json`, `bun.lock`,
  `pnpm-lock.yaml`) as the `input_hash` argument to `compute/3`.

  Returns `{:ok, hex_hash}` on success, or `{:error, reason}` if the file
  cannot be read.
  """
  @spec hash_file(path :: String.t()) :: {:ok, String.t()} | {:error, term()}
  def hash_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        hash = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
        {:ok, hash}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns a lowercase hex SHA-256 hash of a directory tree's contents.

  Walks all regular files under `root` recursively, sorts them by relative path
  (so the hash is independent of filesystem enumeration order), and folds each
  file's relative path and raw contents into a running SHA-256. Two trees with
  identical files, contents, and paths produce identical hashes.

  ## Options

  - `:exclude` — list of top-level directory or file names to skip entirely.
    Defaults to `#{inspect(@default_tree_excludes)}`.

  Returns `{:ok, hex_hash}` on success, or `{:error, reason}` if the root
  directory cannot be read or any file within it cannot be read.
  """
  @spec hash_tree(root :: String.t(), opts :: keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def hash_tree(root, opts \\ []) do
    excludes = Keyword.get(opts, :exclude, @default_tree_excludes)

    with {:ok, rel_paths} <- collect_rel_paths(root, excludes) do
      sorted = Enum.sort(rel_paths)

      state = :crypto.hash_init(:sha256)

      result =
        Enum.reduce_while(sorted, {:ok, state}, fn rel_path, {:ok, acc_state} ->
          abs_path = Path.join(root, rel_path)

          case File.read(abs_path) do
            {:ok, contents} ->
              next_state =
                acc_state
                |> :crypto.hash_update(rel_path)
                |> :crypto.hash_update(contents)

              {:cont, {:ok, next_state}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      case result do
        {:ok, final_state} ->
          hash = :crypto.hash_final(final_state) |> Base.encode16(case: :lower)
          {:ok, hash}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Hash a single component to a fixed-length binary digest (32 bytes).
  # nil is encoded as the literal string "nil", distinct from "".
  defp hash_component(nil), do: :crypto.hash(:sha256, "nil")
  defp hash_component(value), do: :crypto.hash(:sha256, value)

  # Recursively collect all regular-file paths relative to root, skipping
  # top-level entries whose basename is in excludes.
  defp collect_rel_paths(root, excludes) do
    case File.ls(root) do
      {:ok, entries} ->
        filtered = Enum.reject(entries, &(&1 in excludes))

        results =
          Enum.reduce_while(filtered, {:ok, []}, fn entry, {:ok, acc} ->
            abs = Path.join(root, entry)

            case File.stat(abs) do
              {:ok, %File.Stat{type: :directory}} ->
                sub_root = abs
                sub_rel_prefix = entry

                case collect_rel_paths(sub_root, []) do
                  {:ok, sub_paths} ->
                    prefixed = Enum.map(sub_paths, &Path.join(sub_rel_prefix, &1))
                    {:cont, {:ok, acc ++ prefixed}}

                  {:error, reason} ->
                    {:halt, {:error, reason}}
                end

              {:ok, %File.Stat{type: :regular}} ->
                {:cont, {:ok, [entry | acc]}}

              {:ok, _other} ->
                # skip symlinks, devices, etc.
                {:cont, {:ok, acc}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end)

        results

      {:error, reason} ->
        {:error, reason}
    end
  end
end
