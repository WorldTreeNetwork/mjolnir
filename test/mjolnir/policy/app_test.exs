defmodule Mjolnir.Policy.AppTest do
  # mjolnir-xuv: the deploy/domain endpoints sat behind require_scope alone. A
  # scope proves WHO is calling, not WHAT they may touch — so any authenticated
  # caller could redeploy, or repoint the custom domain of, another tenant's app.
  # That is the surface that aims hostnames at VMs.
  use ExUnit.Case, async: true

  alias Mjolnir.Policy.App

  @alice %{user_id: "alice"}
  @mallory %{user_id: "mallory"}
  @localhost %{user_id: "localhost"}

  defp app(owner), do: %{owner_id: owner}

  describe "the hole this closes" do
    test "a non-owner cannot retarget another tenant's domain" do
      assert App.authorize(:set_domain, @mallory, app("alice")) == :error
      assert App.authorize(:remove_domain, @mallory, app("alice")) == :error
      assert App.authorize(:issue_cert, @mallory, app("alice")) == :error
    end

    test "a non-owner cannot redeploy another tenant's app" do
      assert App.authorize(:deploy, @mallory, app("alice")) == :error
    end

    test "a non-owner cannot read another tenant's app" do
      assert App.authorize(:read, @mallory, app("alice")) == :error
    end
  end

  describe "owners" do
    for action <- [:read, :deploy, :set_domain, :remove_domain, :issue_cert] do
      test "the owner may #{action}" do
        assert App.authorize(unquote(action), @alice, app("alice")) == :ok
      end
    end
  end

  describe "collection actions" do
    test "any authenticated user may deploy a NEW app or list" do
      assert App.authorize(:deploy_new, @mallory, nil) == :ok
      assert App.authorize(:list, @mallory, nil) == :ok
    end

    test "an unauthenticated user may do nothing" do
      assert App.authorize(:deploy_new, %{user_id: nil}, nil) == :error
      assert App.authorize(:list, %{user_id: nil}, nil) == :error
      assert App.authorize(:read, nil, app("alice")) == :error
    end
  end

  describe "legacy entries (owner_id: nil)" do
    test "are denied to regular users — fail closed, then back-fill" do
      for action <- [:read, :deploy, :set_domain, :remove_domain, :issue_cert] do
        assert App.authorize(action, @alice, app(nil)) == :error,
               "#{action} on an unowned app must not be allowed to a regular user: " <>
                 "every pre-ownership app would otherwise stay world-writable"
      end
    end

    test "are still reachable by localhost so ops can back-fill them" do
      assert App.authorize(:set_domain, @localhost, app(nil)) == :ok
    end
  end

  describe "localhost bypass" do
    test "reaches every action on any app" do
      for action <- [:read, :deploy, :set_domain, :remove_domain, :issue_cert, :deploy_new, :list] do
        assert App.authorize(action, @localhost, app("alice")) == :ok
      end
    end
  end

  describe "filter_readable/2" do
    setup do
      %{
        entries: [
          %{app_name: "a", owner_id: "alice"},
          %{app_name: "m", owner_id: "mallory"},
          %{app_name: "legacy", owner_id: nil}
        ]
      }
    end

    test "a user sees only their own apps", %{entries: entries} do
      assert [%{app_name: "a"}] = App.filter_readable(entries, @alice)
    end

    test "legacy nil-owner apps are hidden from regular users", %{entries: entries} do
      refute Enum.any?(App.filter_readable(entries, @mallory), &(&1.app_name == "legacy"))
    end

    test "localhost sees everything", %{entries: entries} do
      assert length(App.filter_readable(entries, @localhost)) == 3
    end

    test "an unknown action is denied by default" do
      assert App.authorize(:destroy_everything, @alice, app("alice")) == :error
    end
  end
end
