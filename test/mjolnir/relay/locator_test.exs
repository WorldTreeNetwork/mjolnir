defmodule Mjolnir.Relay.LocatorTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Relay.Locator

  @moduletag :tmp_dir
  @endpoint_id String.duplicate("ab", 32)

  setup %{tmp_dir: dir} do
    env = Path.join(dir, "relay.env")
    runtime = Path.join(dir, "locator.json")
    opts = [env_path: env, locator_path: runtime]
    File.write!(env, "MJOLNIR_RELAY_ENABLED=true\nMJOLNIR_RELAY_HOST=relay.example\n")
    publish(runtime, "relay.example", @endpoint_id)
    %{env: env, runtime: runtime, opts: opts}
  end

  test "takes the run-time ID and the configured WebTransport origin as a pair", ctx do
    File.write!(ctx.env, """
    # Host relay configuration
    MJOLNIR_RELAY_ACME_EMAIL='ignored=value@example.org'
    MJOLNIR_RELAY_ENABLED='true'
    MJOLNIR_RELAY_HOST="Relay.Example"
    """)

    assert Locator.read(ctx.opts) == %{
             "relay_url" => "https://relay.example/",
             "relay_iroh_endpoint_id" => @endpoint_id
           }
  end

  test "does not reuse old locators after config changes", ctx do
    assert Map.has_key?(Locator.read(ctx.opts), "relay_url")

    for config <- [
          "MJOLNIR_RELAY_ENABLED=false\nMJOLNIR_RELAY_HOST=relay.example",
          "MJOLNIR_RELAY_HOST=relay.example",
          "MJOLNIR_RELAY_ENABLED=true",
          ~s|MJOLNIR_RELAY_ENABLED="true\nMJOLNIR_RELAY_HOST=relay.example|,
          "MJOLNIR_RELAY_ENABLED=true\nMJOLNIR_RELAY_HOST=renamed.example"
        ] do
      File.write!(ctx.env, config)
      assert Locator.read(ctx.opts) == %{}
    end

    File.rm!(ctx.env)
    assert Locator.read(ctx.opts) == %{}
    File.mkdir!(ctx.env)
    assert Locator.read(ctx.opts) == %{}
  end

  test "rejects an unusable public origin even when the runtime hostname matches", ctx do
    for host <- [
          "relay.example:443",
          "user@relay.example",
          "relay.example/path",
          "relay..example"
        ] do
      File.write!(ctx.env, "MJOLNIR_RELAY_ENABLED=true\nMJOLNIR_RELAY_HOST=#{host}")
      publish(ctx.runtime, host, @endpoint_id)
      assert Locator.read(ctx.opts) == %{}
    end
  end

  test "does not reuse old locators when the runtime document disappears or is invalid", ctx do
    assert Map.has_key?(Locator.read(ctx.opts), "relay_url")

    for id <- ["", String.upcase(@endpoint_id), String.slice(@endpoint_id, 1..-1//1), 123] do
      publish(ctx.runtime, "relay.example", id)
      assert Locator.read(ctx.opts) == %{}
    end

    File.write!(ctx.runtime, "{")
    assert Locator.read(ctx.opts) == %{}
    File.rm!(ctx.runtime)
    assert Locator.read(ctx.opts) == %{}
    File.mkdir!(ctx.runtime)
    assert Locator.read(ctx.opts) == %{}
  end

  test "reads a replacement endpoint ID on the next setup", ctx do
    assert Locator.read(ctx.opts)["relay_iroh_endpoint_id"] == @endpoint_id
    replacement = String.duplicate("cd", 32)
    publish(ctx.runtime, "relay.example", replacement)
    assert Locator.read(ctx.opts)["relay_iroh_endpoint_id"] == replacement
  end

  defp publish(path, host, id) do
    File.write!(path, Jason.encode!(%{"host" => host, "endpoint_id" => id}))
  end
end
