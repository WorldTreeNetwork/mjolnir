defmodule Mjolnir.Deploy.ManifestTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Deploy.{BuildPlan, Detector, Manifest}

  setup do
    dir = Path.join(System.tmp_dir!(), "mjolnir_manifest_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write_manifest(dir, contents) do
    File.write!(Path.join(dir, "mjolnir.toml"), contents)
    dir
  end

  defp scaffold_sveltekit(dir) do
    File.write!(Path.join(dir, "package.json"), "{}")
    File.write!(Path.join(dir, "svelte.config.js"), "export default {};")
    dir
  end

  # ---------------------------------------------------------------------------
  # Absence
  # ---------------------------------------------------------------------------

  describe "no manifest" do
    test "load/1 returns :none so the caller can fall back to inference", %{dir: dir} do
      assert Manifest.load(dir) == :none
      refute Manifest.present?(dir)
    end
  end

  # ---------------------------------------------------------------------------
  # The motivating case: a stack the detector knows nothing about
  # ---------------------------------------------------------------------------

  describe "a Rust app with no Node markers at all" do
    setup %{dir: dir} do
      write_manifest(dir, """
      runtime = "rust@1.83"
      steps = ["cargo build --release"]
      start_command = "./target/release/myapp"
      port = 8080
      """)

      :ok
    end

    test "produces a usable BuildPlan", %{dir: dir} do
      assert {:ok, %BuildPlan{} = plan} = Manifest.load(dir)
      assert plan.runtime == "rust@1.83"
      assert plan.start_command == "./target/release/myapp"
      assert plan.port == 8080
    end

    test "Detector.detect/1 honours it despite the absence of package.json", %{dir: dir} do
      refute File.exists?(Path.join(dir, "package.json"))
      assert {:ok, %BuildPlan{start_command: "./target/release/myapp"}} = Detector.detect(dir)
    end

    test "package_manager is nil — nothing Node to infer", %{dir: dir} do
      assert {:ok, %BuildPlan{package_manager: nil}} = Manifest.load(dir)
    end

    test "the declared runtime gets a mise install prepended", %{dir: dir} do
      # Without this the toolchain is declared but never installed, and the
      # build silently runs against whatever the base image ships.
      assert {:ok, %BuildPlan{steps: ["mise install", "cargo build --release"]}} =
               Manifest.load(dir)
    end
  end

  # ---------------------------------------------------------------------------
  # Precedence
  # ---------------------------------------------------------------------------

  describe "manifest alongside a detectable framework" do
    test "the manifest wins outright — explicit beats inferred", %{dir: dir} do
      dir
      |> scaffold_sveltekit()
      |> write_manifest("""
      start_command = "bin/custom-server"
      port = 9999
      """)

      assert {:ok, plan} = Detector.detect(dir)
      assert plan.start_command == "bin/custom-server"
      assert plan.port == 9999
      # Not the SvelteKit defaults.
      refute plan.start_command == "node build/index.js"
      assert plan.package_manager == nil
    end
  end

  describe "no manifest, detectable framework" do
    test "inference still runs unchanged", %{dir: dir} do
      scaffold_sveltekit(dir)
      assert {:ok, plan} = Detector.detect(dir)
      assert plan.start_command == "node build/index.js"
      assert plan.package_manager == :npm
    end
  end

  # ---------------------------------------------------------------------------
  # A broken manifest must fail loudly, never degrade to inference
  # ---------------------------------------------------------------------------

  describe "malformed manifest" do
    test "invalid TOML is an error, not a fallback", %{dir: dir} do
      dir
      |> scaffold_sveltekit()
      |> write_manifest("this is not = = toml")

      assert {:error, {:invalid_manifest, msg}} = Detector.detect(dir)
      assert msg =~ "not valid TOML"
    end

    test "a valid SvelteKit app does NOT rescue a broken manifest", %{dir: dir} do
      # The whole point: silently deploying the inferred app would run something
      # other than what the author described.
      dir
      |> scaffold_sveltekit()
      |> write_manifest("port = 3000")

      assert {:error, {:invalid_manifest, _}} = Detector.detect(dir)
    end
  end

  describe "validation" do
    test "start_command is required", %{dir: dir} do
      write_manifest(dir, "port = 8080")
      assert {:error, {:invalid_manifest, msg}} = Manifest.load(dir)
      assert msg =~ "start_command is required"
    end

    test "port is required", %{dir: dir} do
      write_manifest(dir, ~s(start_command = "./run"))
      assert {:error, {:invalid_manifest, msg}} = Manifest.load(dir)
      assert msg =~ "port is required"
    end

    test "port must be an integer in range", %{dir: dir} do
      write_manifest(dir, ~s(start_command = "./run"\nport = 70000))
      assert {:error, {:invalid_manifest, msg}} = Manifest.load(dir)
      assert msg =~ "port must be an integer"
    end

    test "a string port is rejected rather than coerced", %{dir: dir} do
      write_manifest(dir, ~s(start_command = "./run"\nport = "8080"))
      assert {:error, {:invalid_manifest, msg}} = Manifest.load(dir)
      assert msg =~ "port must be an integer"
    end

    test "blank start_command is rejected", %{dir: dir} do
      write_manifest(dir, ~s(start_command = "   "\nport = 8080))
      assert {:error, {:invalid_manifest, msg}} = Manifest.load(dir)
      assert msg =~ "must not be blank"
    end

    test "steps must be a list of strings", %{dir: dir} do
      write_manifest(dir, ~s(start_command = "./run"\nport = 8080\nsteps = [1, 2]))
      assert {:error, {:invalid_manifest, msg}} = Manifest.load(dir)
      assert msg =~ "steps must be a list of strings"
    end

    test "a typo'd key is an error, not silently ignored", %{dir: dir} do
      # `start-command` with a hyphen would otherwise be accepted and dropped,
      # and the real failure would surface much later as a missing field.
      write_manifest(dir, ~s(start_command = "./run"\nport = 8080\nstart-command = "./other"))

      assert {:error, {:invalid_manifest, msg}} = Manifest.load(dir)
      assert msg =~ "unknown key"
      assert msg =~ "start-command"
    end
  end

  # ---------------------------------------------------------------------------
  # Optional fields
  # ---------------------------------------------------------------------------

  describe "minimal manifest" do
    test "steps and runtime are optional", %{dir: dir} do
      write_manifest(dir, ~s(start_command = "./prebuilt-binary"\nport = 8080))

      assert {:ok, %BuildPlan{steps: [], runtime: ""}} = Manifest.load(dir)
    end
  end

  describe "author drives mise themselves" do
    test "no second mise install is prepended", %{dir: dir} do
      write_manifest(dir, """
      runtime = "go@1.23"
      steps = ["mise install --yes", "go build ./..."]
      start_command = "./app"
      port = 8080
      """)

      assert {:ok, %BuildPlan{steps: ["mise install --yes", "go build ./..."]}} =
               Manifest.load(dir)
    end
  end
end
