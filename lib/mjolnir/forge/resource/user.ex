defmodule Mjolnir.Forge.Resource.User do
  @moduledoc """
  Resource kind: a Linux user account.

  Content shape:

      %{
        state: :present | :absent,
        uid: integer() | nil,
        shell: binary() | nil,
        home: binary() | nil,
        groups: [binary()] | nil,
        system: boolean()
      }

  ## Observe strategy

  Probe-backed via `getent passwd <username>`. Parses the colon-delimited
  record into uid, home, shell. Group membership is probed via `id -Gn <user>`.

  ## Apply semantics

  - `:present` — `useradd` (create) or `usermod` (update). Flags:
    `--uid`, `--shell`, `--home`, `--groups` (supplementary), `--system`.
  - `:absent` — `userdel --remove <user>`

  ## Sandbox support

  When `config :mjolnir, :forge_user_sandbox` is `true`, all user commands
  are stubbed and the module uses an ETS table to simulate user state.
  """

  @behaviour Mjolnir.Forge.Resource

  @impl true
  def kind, do: "user"

  @impl true
  def canonical(%{state: state} = content) do
    parts = [
      "state=#{state}",
      if(content[:uid], do: "uid=#{content.uid}"),
      if(content[:shell], do: "shell=#{content.shell}"),
      if(content[:home], do: "home=#{content.home}"),
      if(content[:groups], do: "groups=#{Enum.sort(content.groups) |> Enum.join(",")}")
    ]

    parts |> Enum.reject(&is_nil/1) |> Enum.join(";")
  end

  @impl true
  def observe_path(_id), do: :probe

  @impl true
  def parse_observed(bytes) when is_binary(bytes) do
    case String.split(String.trim(bytes), ":") do
      [_name, _pass, uid, _gid, _gecos, home, shell] ->
        %{
          state: :present,
          uid: String.to_integer(uid),
          shell: shell,
          home: home,
          groups: nil,
          system: false
        }

      _ ->
        %{state: :absent}
    end
  end

  @impl true
  def probe(_host, id) do
    if sandbox?() do
      probe_sandbox(id)
    else
      case System.cmd("getent", ["passwd", id], stderr_to_stdout: true) do
        {output, 0} ->
          content = parse_observed(output)
          content = Map.put(content, :groups, probe_groups(id))
          {:ok, content}

        {_, 2} ->
          :missing

        {_, _} ->
          :missing
      end
    end
  end

  @impl true
  def apply(_host, id, %{state: :absent}) do
    if sandbox?() do
      delete_sandbox(id)
    else
      case System.cmd("userdel", ["--remove", id], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {_, 6} -> :ok
        {out, code} -> {:error, {:userdel_failed, code, out}}
      end
    end
  end

  def apply(_host, id, %{state: :present} = content) do
    if sandbox?() do
      apply_sandbox(id, content)
    else
      case user_exists?(id) do
        true -> modify_user(id, content)
        false -> create_user(id, content)
      end
    end
  end

  @impl true
  def delete(_host, id) do
    if sandbox?() do
      delete_sandbox(id)
    else
      case System.cmd("userdel", ["--remove", id], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {_, 6} -> :ok
        {out, code} -> {:error, {:userdel_failed, code, out}}
      end
    end
  end

  @impl true
  def to_declaration(name, %{state: state} = content) do
    fields =
      [
        {:state, inspect(state)},
        content[:uid] && {:uid, inspect(content.uid)},
        content[:shell] && {:shell, inspect(content.shell)},
        content[:home] && {:home, inspect(content.home)},
        content[:groups] && {:groups, inspect(content.groups)},
        content[:system] && {:system, inspect(content.system)}
      ]
      |> Enum.filter(& &1)

    Mjolnir.Forge.Resource.render_block("user", name, fields)
  end

  @impl true
  def enumerate(_host) do
    if sandbox?() do
      list_sandbox_ids()
    else
      # Regular accounts only (uid 1000..64999) — skip system users and the
      # nobody sentinel so discovery surfaces the handful of real accounts.
      case System.cmd("getent", ["passwd"], stderr_to_stdout: true) do
        {out, 0} -> out |> String.split("\n", trim: true) |> Enum.flat_map(&regular_user/1)
        {_, _} -> []
      end
    end
  end

  defp regular_user(line) do
    case String.split(line, ":") do
      [name, _pass, uid | _] ->
        case Integer.parse(uid) do
          {n, _} when n >= 1000 and n < 65000 -> [name]
          _ -> []
        end

      _ ->
        []
    end
  end

  # -- Real commands --

  defp user_exists?(username) do
    case System.cmd("getent", ["passwd", username], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp create_user(username, content) do
    args = build_useradd_args(username, content)

    case System.cmd("useradd", args, stderr_to_stdout: true) do
      {_, 0} -> maybe_set_groups(username, content[:groups])
      {out, code} -> {:error, {:useradd_failed, code, out}}
    end
  end

  defp modify_user(username, content) do
    args = build_usermod_args(username, content)

    if args == [username] do
      maybe_set_groups(username, content[:groups])
    else
      case System.cmd("usermod", args, stderr_to_stdout: true) do
        {_, 0} -> maybe_set_groups(username, content[:groups])
        {out, code} -> {:error, {:usermod_failed, code, out}}
      end
    end
  end

  defp build_useradd_args(username, content) do
    args = []
    args = if content[:system], do: ["--system" | args], else: args
    args = if content[:uid], do: ["--uid", to_string(content.uid) | args], else: args
    args = if content[:shell], do: ["--shell", content.shell | args], else: args
    args = if content[:home], do: ["--home-dir", content.home, "--create-home" | args], else: args
    Enum.reverse(args) ++ [username]
  end

  defp build_usermod_args(username, content) do
    args = []
    args = if content[:uid], do: ["--uid", to_string(content.uid) | args], else: args
    args = if content[:shell], do: ["--shell", content.shell | args], else: args
    args = if content[:home], do: ["--home", content.home | args], else: args
    Enum.reverse(args) ++ [username]
  end

  defp maybe_set_groups(_username, nil), do: :ok
  defp maybe_set_groups(_username, []), do: :ok

  defp maybe_set_groups(username, groups) when is_list(groups) do
    case System.cmd("usermod", ["--groups", Enum.join(groups, ","), username],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:groups_failed, code, out}}
    end
  end

  defp probe_groups(username) do
    case System.cmd("id", ["-Gn", username], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> String.split(" ") |> Enum.sort()
      _ -> nil
    end
  end

  # -- Sandbox (ETS-backed) --

  defp sandbox?, do: Application.get_env(:mjolnir, :forge_user_sandbox, false)

  @sandbox_table :forge_user_sandbox

  def ensure_sandbox_table do
    if :ets.whereis(@sandbox_table) == :undefined do
      :ets.new(@sandbox_table, [:named_table, :public, :set])
    end

    :ok
  end

  defp list_sandbox_ids do
    ensure_sandbox_table()
    :ets.tab2list(@sandbox_table) |> Enum.map(fn {id, _content} -> id end)
  end

  defp probe_sandbox(id) do
    ensure_sandbox_table()

    case :ets.lookup(@sandbox_table, id) do
      [{^id, content}] -> {:ok, content}
      [] -> :missing
    end
  end

  defp apply_sandbox(id, content) do
    ensure_sandbox_table()
    :ets.insert(@sandbox_table, {id, content})
    :ok
  end

  defp delete_sandbox(id) do
    ensure_sandbox_table()
    :ets.delete(@sandbox_table, id)
    :ok
  end
end
