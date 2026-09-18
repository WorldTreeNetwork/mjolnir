defmodule Mjolnir.Auth.LoginTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Auth.{Login, Oidc}

  describe "safe_next/1" do
    test "accepts a term path with optional session" do
      id = "01234567-89ab-cdef-0123-456789abcdef"
      assert Login.safe_next("/term/#{id}") == "/term/#{id}"
      assert Login.safe_next("/term/#{id}?session=main") == "/term/#{id}?session=main"
    end

    test "refuses open redirects and API paths" do
      assert Login.safe_next("https://evil.example/term") == "/"
      assert Login.safe_next("//evil.example") == "/"
      assert Login.safe_next("/api/vms") == "/"
      assert Login.safe_next("/term/../api/vms") == "/"
      assert Login.safe_next(nil) == "/"
    end
  end

  describe "Oidc.classify_token/1" do
    test "a token is success" do
      assert {:ok, "jwt-here"} = Oidc.classify_token(%{"access_token" => "jwt-here"})
    end

    test "id_token is preferred for the code flow" do
      assert {:ok, "id.jwt"} =
               Oidc.classify_token(%{"id_token" => "id.jwt", "access_token" => "at"})
    end

    test "authorization_pending is pending" do
      assert :pending = Oidc.classify_token(%{"error" => "authorization_pending"})
    end

    test "slow_down is its own atom" do
      assert :slow_down = Oidc.classify_token(%{"error" => "slow_down"})
    end

    test "anything else is an error" do
      assert {:error, {:oidc_error, "access_denied"}} =
               Oidc.classify_token(%{"error" => "access_denied"})
    end
  end
end
