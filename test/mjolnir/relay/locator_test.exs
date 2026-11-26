defmodule Mjolnir.Relay.LocatorTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

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

  @tag hostile_special_file: :fifo
  test "rejects a FIFO without opening it", ctx do
    File.rm!(ctx.runtime)
    assert {_, 0} = System.cmd("mkfifo", [ctx.runtime], stderr_to_stdout: true)
    assert_rejected(ctx.opts, "non-regular file (other)")
  end

  @tag hostile_special_file: :dev_zero
  test "rejects a symlink to /dev/zero without reading it", ctx do
    assert File.exists?("/dev/zero")
    File.rm!(ctx.runtime)
    File.ln_s!("/dev/zero", ctx.runtime)
    assert_rejected(ctx.opts, "non-regular file (symlink)")
  end

  test "rejects a symlink even to a valid regular locator", ctx do
    target = ctx.runtime <> ".target"
    File.rename!(ctx.runtime, target)
    File.ln_s!(target, ctx.runtime)
    assert_rejected(ctx.opts, "non-regular file (symlink)")
  end

  test "rejects a directory at the locator path", ctx do
    File.rm!(ctx.runtime)
    File.mkdir!(ctx.runtime)
    assert_rejected(ctx.opts, "non-regular file (directory)")
  end

  test "rejects an oversized regular file even when its JSON is valid", ctx do
    pad_to_limit_plus_one(ctx.runtime)
    assert_rejected(ctx.opts, "file exceeds 4096 bytes")
  end

  test "rejects a regular file that grows beyond 4 KiB after lstat", ctx do
    lstat = fn path ->
      stat = File.lstat(path)
      pad_to_limit_plus_one(path)
      stat
    end

    assert_rejected([{:lstat, lstat} | ctx.opts], "file exceeds 4096 bytes")
  end

  test "rejects a different file substituted after lstat", ctx do
    target = ctx.runtime <> ".target"
    publish(target, "relay.example", String.duplicate("cd", 32))

    lstat = fn path ->
      stat = File.lstat(path)
      File.rm!(path)
      File.ln_s!(target, path)
      stat
    end

    assert_rejected([{:lstat, lstat} | ctx.opts], "file changed after lstat")
  end

  test "returns no locator when the file worker stalls", ctx do
    caller = self()

    lstat = fn _path ->
      send(caller, {:stalled, self()})
      Process.sleep(:infinity)
    end

    start = System.monotonic_time(:millisecond)
    assert_rejected([{:lstat, lstat} | ctx.opts], "timed out")
    assert System.monotonic_time(:millisecond) - start < 1_500
    assert_receive {:stalled, worker}
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
  end

  test "rejects malformed JSON, extra keys, and non-string values without logging them", ctx do
    for json <- [
          "{ not-a-locator",
          ~s({"host":"relay.example","endpoint_id":"#{@endpoint_id}","extra":"not-a-locator"}),
          ~s({"host":"relay.example","endpoint_id":"#{@endpoint_id}","host":"relay.example"}),
          ~s({"host":123,"endpoint_id":"#{@endpoint_id}"}),
          ~s({"host":"relay.example","endpoint_id":["not-a-locator"]})
        ] do
      File.write!(ctx.runtime, json)
      assert_rejected(ctx.opts, "invalid JSON or schema")
    end
  end

  test "warns once for invalid locator values without logging them", ctx do
    publish(ctx.runtime, "other.example", @endpoint_id)
    assert_rejected(ctx.opts, "hostname mismatch")
    publish(ctx.runtime, "relay.example", "not-a-locator")
    assert_rejected(ctx.opts, "invalid endpoint ID")
  end

  defp assert_rejected(opts, reason) do
    {result, log} = with_log(fn -> Locator.read(opts) end)
    assert result == %{}
    assert [_] = Regex.scan(~r/relay locator rejected:/, log)
    assert log =~ "relay locator rejected: " <> reason
    refute log =~ "not-a-locator"
    refute log =~ @endpoint_id
  end

  defp pad_to_limit_plus_one(path) do
    File.write!(path, String.duplicate(" ", 4097 - File.stat!(path).size), [:append])
  end

  defp publish(path, host, id) do
    File.write!(path, Jason.encode!(%{"host" => host, "endpoint_id" => id}))
  end
end
