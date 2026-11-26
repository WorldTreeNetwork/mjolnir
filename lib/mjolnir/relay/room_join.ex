defmodule Mjolnir.Relay.RoomJoin do
  @moduledoc """
  Smallest client identity guard for an open or protected room join.

  There is no browser call client in this repository (`mjolnir-rurh.15` and
  `mjolnir-rurh.5` have no landing tree). This module is the check those
  clients call on join, credential replacement, and renewal. It does not
  open a socket, render a page, or talk to the gateway. Wiring it into a
  page is the integration gate on those nodes.

  `expected_root` comes from the invitation, not from the token.
  `asked` is what the person requested: `:open` or `:protected`.
  `response` is the mint JSON, including `token`, `root`, and `kind`
  when the mint sent one.
  """

  @spec check(String.t(), :open | :protected, map()) ::
          {:ok, %{kind: :open | :protected, root: String.t()}}
          | {:error, atom()}
  def check(expected_root, asked, response)
      when is_binary(expected_root) and asked in [:open, :protected] and is_map(response) do
    with {:ok, token_root} <- token_root(response),
         :ok <- roots_agree(expected_root, token_root, response),
         class when class in [:open, :protected] <- Mjolnir.Relay.RoomClass.classify(token_root),
         :ok <- kind_agrees(class, response),
         :ok <- asked_agrees(asked, class, response) do
      {:ok, %{kind: class, root: token_root}}
    else
      :invalid -> {:error, :invalid_root}
      {:error, reason} -> {:error, reason}
    end
  end

  def check(_, _, _), do: {:error, :invalid_response}

  defp token_root(response) when is_map(response) do
    token_root_value(response["token"] || response[:token])
  end

  defp token_root(_), do: {:error, :bad_token}

  defp token_root_value(token) when is_binary(token) do
    case String.split(token, ".") do
      [_header, payload, _sig] ->
        with {:ok, json} <- Base.url_decode64(payload, padding: false),
             {:ok, claims} <- Jason.decode(json),
             root when is_binary(root) <- claims["root"] do
          {:ok, root}
        else
          _ -> {:error, :bad_token}
        end

      _ ->
        {:error, :bad_token}
    end
  end

  defp token_root_value(_), do: {:error, :bad_token}

  defp roots_agree(expected, token_root, response) do
    response_root = response["root"] || response[:root]

    cond do
      expected != token_root -> {:error, :unexpected_root}
      response_root != token_root -> {:error, :response_root_mismatch}
      true -> :ok
    end
  end

  defp kind_agrees(class, response) do
    case response["kind"] || response[:kind] do
      nil -> :ok
      "open" when class == :open -> :ok
      "protected" when class == :protected -> :ok
      kind when is_binary(kind) -> {:error, :kind_mismatch}
      _ -> {:error, :kind_mismatch}
    end
  end

  # An explicit open request fails closed on the old mint, which has no
  # `kind` and a protected root. A protected request does not accept an
  # open root as plaintext.
  defp asked_agrees(:open, :open, %{"kind" => "open"}), do: :ok
  defp asked_agrees(:open, :open, %{kind: "open"}), do: :ok
  defp asked_agrees(:open, _, _), do: {:error, :open_refused}

  defp asked_agrees(:protected, :protected, response) do
    case response["kind"] || response[:kind] do
      nil -> :ok
      "protected" -> :ok
      _ -> {:error, :protected_refused}
    end
  end

  defp asked_agrees(:protected, _, _), do: {:error, :protected_refused}
end
