defmodule Mjolnir.Gateway.ClassifyTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Gateway.Classify

  @z32_zeros String.duplicate("y", 52)
  @backend "10.0.0.1:3000"

  describe "classify/3" do
    test "no apex is a route-table miss" do
      assert {:ok, :reject} = Classify.classify("blog.example.com", "", [])
    end

    test "a certificate block is not an apex" do
      toml = """
      [[cert]]
      host = "blog.example.com"
      cert_path = "/etc/mjolnir/certs/blog.example.com/fullchain.pem"
      key_path = "/etc/mjolnir/certs/blog.example.com/privkey.pem"
      """

      assert {:ok, :reject} = Classify.classify("blog.example.com", toml, [])
    end

    test "a missing fallthrough is iroh" do
      assert {:ok, :iroh} = Classify.classify("blog.example.com", domain("example.com"), [])
    end

    test "an unquoted suffix is still an apex" do
      toml = """
      [[domain]]
      suffix = example.com
      fallthrough = none
      """

      assert {:ok, :reject} = Classify.classify("blog.example.com", toml, [])
    end

    test "fallthrough none is a miss and parked stays parked" do
      assert {:ok, :reject} =
               Classify.classify("blog.example.com", domain("example.com", "none"), [])

      assert {:ok, :parked} =
               Classify.classify("blog.example.com", domain("example.com", "parked"), [])
    end

    test "a local route wins over fallthrough none" do
      toml = """
      #{domain("example.com", "none")}
      [[route]]
      apex = "example.com"
      subdomain = "blog"
      backend = "#{@backend}"
      """

      assert {:ok, :local} = Classify.classify("blog.example.com", toml, [])
    end

    test "a gateway alias is iroh even when fallthrough is none" do
      toml = """
      #{domain("example.com", "none")}
      [[alias]]
      apex = "example.com"
      subdomain = "blog"
      node = "#{@z32_zeros}"
      """

      assert {:ok, :iroh} = Classify.classify("blog.example.com", toml, [])
    end

    test "a short node is skipped and the host stays a miss" do
      toml = """
      #{domain("example.com", "none")}
      [[alias]]
      apex = "example.com"
      subdomain = "blog"
      node = "not-a-node"
      """

      assert {:ok, :reject} = Classify.classify("blog.example.com", toml, [])
    end

    test "the longest suffix wins" do
      toml = """
      #{domain("example.com", "none")}
      #{domain("apps.example.com", "parked")}
      """

      assert {:ok, :parked} = Classify.classify("git.apps.example.com", toml, [])
      assert {:ok, :reject} = Classify.classify("blog.example.com", toml, [])
    end

    test "a bare apex is a miss unless it is parked or has an empty-subdomain route" do
      assert {:ok, :reject} = Classify.classify("example.com", domain("example.com", "none"), [])
      assert {:ok, :reject} = Classify.classify("example.com", domain("example.com", "iroh"), [])

      assert {:ok, :parked} =
               Classify.classify("example.com", domain("example.com", "parked"), [])

      toml = """
      #{domain("example.com", "none")}
      [[route]]
      apex = "example.com"
      subdomain = ""
      backend = "#{@backend}"
      """

      assert {:ok, :local} = Classify.classify("example.com", toml, [])
    end

    test "a dotted subdomain route is local and a bad backend is skipped" do
      good = """
      #{domain("example.com", "none")}
      [[route]]
      apex = "example.com"
      subdomain = "git.api"
      backend = "[::1]:80"
      """

      assert {:ok, :local} = Classify.classify("git.api.example.com", good, [])

      bad = """
      #{domain("example.com", "none")}
      [[route]]
      apex = "example.com"
      subdomain = "blog"
      backend = "not-a-socket"
      """

      assert {:ok, :reject} = Classify.classify("blog.example.com", bad, [])
    end

    test "an orphan route is skipped" do
      toml = """
      #{domain("example.com", "none")}
      [[route]]
      apex = "not-declared.com"
      subdomain = "blog"
      backend = "#{@backend}"
      """

      assert {:ok, :reject} = Classify.classify("blog.example.com", toml, [])
    end

    test "the first fallthrough wins when a suffix is repeated" do
      toml = """
      #{domain("example.com", "parked")}
      #{domain("example.com", "none")}
      """

      assert {:ok, :parked} = Classify.classify("blog.example.com", toml, [])
    end

    test "an invalid fallthrough or a wildcard suffix fails closed" do
      assert {:error, :gateway_config_unreadable} =
               Classify.classify("blog.example.com", domain("example.com", "nope"), [])

      assert {:error, :gateway_config_unreadable} =
               Classify.classify("blog.example.com", domain("*.example.com"), [])
    end

    test "a host port is stripped before matching" do
      assert {:ok, :iroh} =
               Classify.classify("Blog.Example.com:443", domain("example.com"), [])
    end

    test "a drop-in route is local and a drop-in apex is ignored" do
      base = domain("example.com", "none")

      route = """
      [[route]]
      apex = "example.com"
      subdomain = "blog"
      backend = "#{@backend}"
      """

      assert {:ok, :local} = Classify.classify("blog.example.com", base, [route])

      extra_apex = """
      [[domain]]
      suffix = "*.ignored.test"
      fallthrough = "iroh"

      [[domain]]
      suffix = "other.test"
      fallthrough = "parked"
      """

      assert {:ok, :reject} = Classify.classify("www.other.test", base, [extra_apex])
      assert {:ok, :reject} = Classify.classify("blog.example.com", base, [extra_apex])
    end
  end

  describe "for_host/1" do
    test "a missing base file is an empty route table" do
      dir = tmp!("enoent")
      path = Path.join(dir, "gateway.toml")
      dropins = Path.join(dir, "gateway.d")
      File.mkdir_p!(dropins)

      File.write!(Path.join(dropins, "route.toml"), """
      [[route]]
      apex = "example.com"
      subdomain = "blog"
      backend = "#{@backend}"
      """)

      pin!(path, dropins)

      assert {:ok, :reject} = Classify.for_host("blog.example.com")
    end

    test "a base path that is a directory is unreadable" do
      dir = tmp!("eisdir")
      pin!(dir, Path.join(dir, "no-such-dropins"))

      assert {:error, :gateway_config_unreadable} = Classify.for_host("blog.example.com")
    end

    test "an unreadable drop-in is skipped and a sibling route still applies" do
      dir = tmp!("dropins")
      path = Path.join(dir, "gateway.toml")

      File.write!(path, """
      [[domain]]
      suffix = "example.com"
      fallthrough = "none"
      """)

      dropins = Path.join(dir, "gateway.d")
      File.mkdir_p!(Path.join(dropins, "00-bad.toml"))

      File.write!(Path.join(dropins, "05-wild.toml"), """
      [[domain]]
      suffix = "*.bad.test"
      """)

      File.write!(Path.join(dropins, "10-route.toml"), """
      [[route]]
      apex = "example.com"
      subdomain = "blog"
      backend = "#{@backend}"
      """)

      Process.put(:mjolnir_gateway_toml_path, path)
      Process.delete(:mjolnir_gateway_config_d)

      on_exit(fn ->
        Process.delete(:mjolnir_gateway_toml_path)
        Process.delete(:mjolnir_gateway_config_d)
        File.rm_rf(dir)
      end)

      assert {:ok, :local} = Classify.for_host("blog.example.com")
    end
  end

  defp domain(suffix, fallthrough \\ nil) do
    body =
      if fallthrough do
        "suffix = \"#{suffix}\"\nfallthrough = \"#{fallthrough}\"\n"
      else
        "suffix = \"#{suffix}\"\n"
      end

    "[[domain]]\n" <> body
  end

  defp tmp!(name) do
    path =
      Path.join(System.tmp_dir!(), "mj-classify-#{name}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    path
  end

  defp pin!(toml_path, dropins) do
    Process.put(:mjolnir_gateway_toml_path, toml_path)
    Process.put(:mjolnir_gateway_config_d, dropins)
    root = if File.dir?(toml_path), do: toml_path, else: Path.dirname(toml_path)

    on_exit(fn ->
      Process.delete(:mjolnir_gateway_toml_path)
      Process.delete(:mjolnir_gateway_config_d)
      File.rm_rf(root)
    end)
  end
end
