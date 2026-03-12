defmodule Mjolnir.API.Validation do
  @moduledoc """
  Input validation for API boundary defense.

  All user-supplied strings that flow into shell commands, filesystem paths,
  or wire protocols are validated here before entering the system.

  Defense-in-depth: domain modules (BTRFS, VM) re-validate at their own
  boundaries, but this module catches bad input at the earliest point.
  """

  @doc """
  Validate a "safe name" — used for snapshot names, base image names, and
  session names. Only allows alphanumeric characters, hyphens, underscores,
  and dots. No path separators, no null bytes, no tmux target syntax.

  Returns `{:ok, name}` or `{:error, message}`.
  """
  def validate_safe_name(nil, _label), do: {:error, "is required"}
  def validate_safe_name("", _label), do: {:error, "cannot be empty"}

  def validate_safe_name(name, label) when is_binary(name) do
    cond do
      byte_size(name) > 128 ->
        {:error, "#{label} too long (max 128 characters)"}

      not Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/, name) ->
        {:error,
         "#{label} must start with alphanumeric and contain only alphanumeric, dot, hyphen, or underscore"}

      String.contains?(name, "..") ->
        {:error, "#{label} must not contain '..'"}

      true ->
        {:ok, name}
    end
  end

  def validate_safe_name(_, label), do: {:error, "#{label} must be a string"}

  @doc """
  Validate a session name — stricter than safe_name (no dots allowed,
  because tmux interprets dots as pane separators in target syntax).

  Returns `{:ok, name}` or `{:error, message}`.
  """
  def validate_session_name(nil, _label), do: {:ok, "dev"}
  def validate_session_name("", _label), do: {:ok, "dev"}

  def validate_session_name(name, label) when is_binary(name) do
    cond do
      byte_size(name) > 64 ->
        {:error, "#{label} too long (max 64 characters)"}

      not Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/, name) ->
        {:error,
         "#{label} must start with alphanumeric and contain only alphanumeric, hyphen, or underscore"}

      true ->
        {:ok, name}
    end
  end

  def validate_session_name(_, label), do: {:error, "#{label} must be a string"}

  @doc """
  Validate a command string — must be a non-empty string with a length limit
  and no null bytes.

  Returns `{:ok, command}` or `{:error, message}`.
  """
  def validate_command(nil), do: {:error, "command is required"}

  def validate_command(command) when is_binary(command) do
    cond do
      command == "" ->
        {:error, "command cannot be empty"}

      byte_size(command) > 65_536 ->
        {:error, "command too long (max 64KB)"}

      String.contains?(command, <<0>>) ->
        {:error, "command must not contain null bytes"}

      true ->
        {:ok, command}
    end
  end

  def validate_command(_), do: {:error, "command must be a string"}

  @doc """
  Validate and clamp a timeout value. Returns a positive integer within bounds.
  Non-integer or out-of-range values are replaced with the default.
  """
  def validate_timeout(nil, default, _max), do: default

  def validate_timeout(val, default, max) when is_integer(val) do
    cond do
      val < 1 -> default
      val > max -> max
      true -> val
    end
  end

  def validate_timeout(_, default, _max), do: default

  @doc """
  Parse and validate scrollback_lines from a query string value.
  Returns a bounded integer, defaulting to 100.
  """
  def validate_scrollback_lines(nil), do: 100

  def validate_scrollback_lines(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} when n > 0 and n <= 10_000 -> n
      _ -> 100
    end
  end

  def validate_scrollback_lines(_), do: 100

  @doc """
  Validate a VM ID matches UUID format.
  Returns `{:ok, id}` or `{:error, message}`.
  """
  def validate_vm_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, id) do
      {:ok, id}
    else
      {:error, "invalid VM ID format"}
    end
  end

  def validate_vm_id(_), do: {:error, "VM ID must be a string"}

  @doc """
  Validate an integer parameter is within bounds.
  Returns the value if valid, or the default.
  """
  def validate_integer(nil, default, _min, _max), do: default

  def validate_integer(val, default, min, max) when is_integer(val) do
    if val >= min and val <= max, do: val, else: default
  end

  def validate_integer(_, default, _min, _max), do: default
end
