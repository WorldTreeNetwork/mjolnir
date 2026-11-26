defmodule Mjolnir.Relay.RoomJoin do
  @moduledoc """
  Smallest client identity guard for an open or protected room join.

  There is no browser call client in this repository (`mjolnir-rurh.15` and
  `mjolnir-rurh.5` have no landing tree). This module is a reference identity comparison those
  clients must implement at an authenticated boundary on join, credential replacement, and renewal. It does not
  open a socket, render a page, or talk to the gateway. Wiring it into a
  page is the integration gate on those nodes.

  `expected_root` comes from the invitation, not from the token.
  `asked` is what the person requested: `:open` or `:protected`.
  `response` is the mint JSON, including `token`, `root`, and `kind`
  when the mint sent one. `admission` is a trusted full-admission result
  containing the original authenticated root and exact token, never remote JSON.
  Passing a caller-fabricated success does not authenticate anything.
  """

  # This is an identity comparison seam, not a JWT verifier. The trusted caller
  # must supply successful full admission for this exact credential. No product
  # admission producer or browser lifecycle is wired to this reference helper yet.
  @spec check(String.t(), :open | :protected, map(), tuple()) ::
          {:ok, map()} | {:error, atom()}
  def check(expected_root, asked, response, admission)
      when is_binary(expected_root) and asked in [:open, :protected] and is_map(response) do
    with {:ok, token} when is_binary(token) <- field(response, "token", :token),
         {:ok, token_root} <- admitted_root(admission, token),
         :ok <- roots_agree(expected_root, token_root, response),
         class when class in [:open, :protected] <- Mjolnir.Relay.RoomClass.classify(token_root),
         :ok <- kind_agrees(class, response),
         :ok <- asked_agrees(asked, class, response) do
      {:ok, %{kind: class, root: token_root}}
    else
      :invalid -> {:error, :invalid_root}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_response}
    end
  end

  def check(_, _, _, _), do: {:error, :invalid_response}

  defp admitted_root({:ok, %{token: token, root: root}}, token) when is_binary(root),
    do: {:ok, root}

  defp admitted_root(_, _), do: {:error, :unauthenticated_identity}

  defp field(map, string, atom) do
    case {Map.fetch(map, string), Map.fetch(map, atom)} do
      {:error, :error} -> :error
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {{:ok, value}, {:ok, value}} -> {:ok, value}
      _ -> {:error, :conflicting_fields}
    end
  end

  defp roots_agree(expected, token_root, response) do
    response_root = field(response, "root", :root)

    cond do
      expected != token_root -> {:error, :unexpected_root}
      response_root != {:ok, token_root} -> {:error, :response_root_mismatch}
      true -> :ok
    end
  end

  defp kind_agrees(class, response) do
    case field(response, "kind", :kind) do
      :error when class == :protected -> :ok
      {:ok, "open"} when class == :open -> :ok
      {:ok, "protected"} when class == :protected -> :ok
      _ -> {:error, :kind_mismatch}
    end
  end

  defp asked_agrees(class, class, _), do: :ok
  defp asked_agrees(:open, _, _), do: {:error, :open_refused}
  defp asked_agrees(:protected, _, _), do: {:error, :protected_refused}
end
