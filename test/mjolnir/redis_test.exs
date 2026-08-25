defmodule Mjolnir.RedisTest do
  use ExUnit.Case, async: false

  alias Mjolnir.Redis

  setup do
    tmp = Path.join(System.tmp_dir!(), "mjolnir-redis-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    pass = Path.join(tmp, "redis.pass")
    conf = Path.join(tmp, "redis.pass.conf")
    secrets = Path.join(tmp, "secrets")
    File.mkdir_p!(secrets)

    prev = %{
      pass: Application.get_env(:mjolnir, :redis_pass_file),
      conf: Application.get_env(:mjolnir, :redis_pass_conf),
      secrets: Application.get_env(:mjolnir, :deploy_secrets_dir),
      ip: Application.get_env(:mjolnir, :host_api_ip)
    }

    Application.put_env(:mjolnir, :redis_pass_file, pass)
    Application.put_env(:mjolnir, :redis_pass_conf, conf)
    Application.put_env(:mjolnir, :deploy_secrets_dir, secrets)
    Application.put_env(:mjolnir, :host_api_ip, "10.200.0.1")

    on_exit(fn ->
      restore(:redis_pass_file, prev.pass)
      restore(:redis_pass_conf, prev.conf)
      restore(:deploy_secrets_dir, prev.secrets)
      restore(:host_api_ip, prev.ip)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, pass: pass, secrets: secrets}
  end

  test "REDIS_URL is overlay TCP with URI-encoded password" do
    url = Redis.redis_url("p/a+ss", "10.200.0.1")
    assert url == "redis://:p%2Fa%2Bss@10.200.0.1:6379/0"
    refute url =~ "0.0.0.0"
  end

  test "ensure merges REDIS_URL without dropping DATABASE_URL", %{secrets: secrets, pass: pass} do
    path = Path.join(secrets, "hypersigil-api.json")
    File.write!(path, Jason.encode!(%{"DATABASE_URL" => "postgres://x"}))

    assert {:ok, result} = Redis.ensure("hypersigil-api")
    assert result.slug == "hypersigil-api"
    assert String.starts_with?(result.url, "redis://:")
    assert String.contains?(result.url, "@10.200.0.1:6379/0")

    map = path |> File.read!() |> Jason.decode!()
    assert map["DATABASE_URL"] == "postgres://x"
    assert map["REDIS_URL"] == result.url
    assert File.read!(pass) |> String.trim() != ""
  end

  test "ensure is idempotent on the password", %{pass: pass} do
    assert {:ok, first} = Redis.ensure("hypersigil-api")
    stored = File.read!(pass)
    assert {:ok, second} = Redis.ensure("hypersigil-api")
    assert first.url == second.url
    assert File.read!(pass) == stored
  end

  test "invalid slug is refused" do
    assert {:error, {:invalid_slug, _}} = Redis.ensure("Hypersigil")
  end

  defp restore(key, nil), do: Application.delete_env(:mjolnir, key)
  defp restore(key, val), do: Application.put_env(:mjolnir, key, val)
end
