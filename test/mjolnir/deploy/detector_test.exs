defmodule Mjolnir.Deploy.DetectorTest do
  use ExUnit.Case, async: true

  alias Mjolnir.Deploy.{BuildPlan, Detector}

  # Build a fresh temp directory for each test so tests never interfere.
  setup do
    dir = Path.join(System.tmp_dir!(), "mjolnir_detector_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  # Write a minimal SvelteKit marker set (both required files) into dir.
  defp scaffold_sveltekit(dir) do
    File.write!(Path.join(dir, "package.json"), "{}")
    File.write!(Path.join(dir, "svelte.config.js"), "export default {};")
    dir
  end

  # Write a specific lockfile into dir (after scaffolding).
  defp write_lockfile(dir, filename) do
    File.write!(Path.join(dir, filename), "")
    dir
  end

  # ---------------------------------------------------------------------------
  # Missing required files → :unsupported_app
  # ---------------------------------------------------------------------------

  describe "missing svelte.config.js" do
    test "returns {:error, :unsupported_app}", %{dir: dir} do
      File.write!(Path.join(dir, "package.json"), "{}")
      # No svelte.config.js
      assert Detector.detect(dir) == {:error, :unsupported_app}
    end
  end

  describe "missing package.json" do
    test "returns {:error, :unsupported_app}", %{dir: dir} do
      File.write!(Path.join(dir, "svelte.config.js"), "export default {};")
      # No package.json
      assert Detector.detect(dir) == {:error, :unsupported_app}
    end
  end

  describe "both marker files missing" do
    test "returns {:error, :unsupported_app}", %{dir: dir} do
      assert Detector.detect(dir) == {:error, :unsupported_app}
    end
  end

  # ---------------------------------------------------------------------------
  # No lockfile → default :npm
  # ---------------------------------------------------------------------------

  describe "no lockfile" do
    test "defaults to :npm package manager", %{dir: dir} do
      scaffold_sveltekit(dir)
      assert {:ok, %BuildPlan{package_manager: :npm}} = Detector.detect(dir)
    end

    test "defaults to npm ci install step", %{dir: dir} do
      scaffold_sveltekit(dir)
      {:ok, plan} = Detector.detect(dir)
      assert "npm ci" in plan.steps
    end

    test "defaults to npm run build step", %{dir: dir} do
      scaffold_sveltekit(dir)
      {:ok, plan} = Detector.detect(dir)
      assert "npm run build" in plan.steps
    end
  end

  # ---------------------------------------------------------------------------
  # Lockfile → package_manager detection
  # ---------------------------------------------------------------------------

  describe "bun.lock present" do
    test "detects :bun", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "bun.lock")
      assert {:ok, %BuildPlan{package_manager: :bun}} = Detector.detect(dir)
    end

    test "uses bun install step", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "bun.lock")
      {:ok, plan} = Detector.detect(dir)
      assert "bun install" in plan.steps
    end

    test "uses bun run build step", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "bun.lock")
      {:ok, plan} = Detector.detect(dir)
      assert "bun run build" in plan.steps
    end
  end

  describe "bun.lockb present" do
    test "detects :bun", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "bun.lockb")
      assert {:ok, %BuildPlan{package_manager: :bun}} = Detector.detect(dir)
    end
  end

  describe "pnpm-lock.yaml present" do
    test "detects :pnpm", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "pnpm-lock.yaml")
      assert {:ok, %BuildPlan{package_manager: :pnpm}} = Detector.detect(dir)
    end

    test "uses pnpm install --frozen-lockfile step", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "pnpm-lock.yaml")
      {:ok, plan} = Detector.detect(dir)
      assert "pnpm install --frozen-lockfile" in plan.steps
    end

    test "uses pnpm run build step", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "pnpm-lock.yaml")
      {:ok, plan} = Detector.detect(dir)
      assert "pnpm run build" in plan.steps
    end
  end

  describe "yarn.lock present" do
    test "detects :yarn", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "yarn.lock")
      assert {:ok, %BuildPlan{package_manager: :yarn}} = Detector.detect(dir)
    end

    test "uses yarn install --frozen-lockfile step", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "yarn.lock")
      {:ok, plan} = Detector.detect(dir)
      assert "yarn install --frozen-lockfile" in plan.steps
    end

    test "uses yarn build step", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "yarn.lock")
      {:ok, plan} = Detector.detect(dir)
      assert "yarn build" in plan.steps
    end
  end

  describe "package-lock.json present" do
    test "detects :npm", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "package-lock.json")
      assert {:ok, %BuildPlan{package_manager: :npm}} = Detector.detect(dir)
    end

    test "uses npm ci step", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "package-lock.json")
      {:ok, plan} = Detector.detect(dir)
      assert "npm ci" in plan.steps
    end

    test "uses npm run build step", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "package-lock.json")
      {:ok, plan} = Detector.detect(dir)
      assert "npm run build" in plan.steps
    end
  end

  # ---------------------------------------------------------------------------
  # Lockfile priority: bun > pnpm > yarn > npm
  # ---------------------------------------------------------------------------

  describe "lockfile priority" do
    test "bun.lock beats pnpm-lock.yaml", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "bun.lock")
      write_lockfile(dir, "pnpm-lock.yaml")
      assert {:ok, %BuildPlan{package_manager: :bun}} = Detector.detect(dir)
    end

    test "bun.lock beats yarn.lock", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "bun.lock")
      write_lockfile(dir, "yarn.lock")
      assert {:ok, %BuildPlan{package_manager: :bun}} = Detector.detect(dir)
    end

    test "bun.lock beats package-lock.json", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "bun.lock")
      write_lockfile(dir, "package-lock.json")
      assert {:ok, %BuildPlan{package_manager: :bun}} = Detector.detect(dir)
    end

    test "pnpm-lock.yaml beats yarn.lock", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "pnpm-lock.yaml")
      write_lockfile(dir, "yarn.lock")
      assert {:ok, %BuildPlan{package_manager: :pnpm}} = Detector.detect(dir)
    end

    test "pnpm-lock.yaml beats package-lock.json", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "pnpm-lock.yaml")
      write_lockfile(dir, "package-lock.json")
      assert {:ok, %BuildPlan{package_manager: :pnpm}} = Detector.detect(dir)
    end

    test "yarn.lock beats package-lock.json", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "yarn.lock")
      write_lockfile(dir, "package-lock.json")
      assert {:ok, %BuildPlan{package_manager: :yarn}} = Detector.detect(dir)
    end

    test "all four lockfiles present → bun wins", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "bun.lock")
      write_lockfile(dir, "pnpm-lock.yaml")
      write_lockfile(dir, "yarn.lock")
      write_lockfile(dir, "package-lock.json")
      assert {:ok, %BuildPlan{package_manager: :bun}} = Detector.detect(dir)
    end
  end

  # ---------------------------------------------------------------------------
  # Full BuildPlan shape for a representative bun SvelteKit app
  # ---------------------------------------------------------------------------

  describe "full BuildPlan for bun SvelteKit app" do
    test "all fields match expected shape", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "bun.lock")

      assert {:ok, plan} = Detector.detect(dir)

      assert %BuildPlan{
               runtime: "node@20",
               package_manager: :bun,
               steps: ["mise install", "bun install", "bun run build"],
               start_command: "node build/index.js",
               port: 3000,
               base_image: nil
             } = plan
    end

    test "steps are ordered: mise install → install → build", %{dir: dir} do
      scaffold_sveltekit(dir)
      write_lockfile(dir, "bun.lock")

      {:ok, plan} = Detector.detect(dir)

      assert plan.steps == ["mise install", "bun install", "bun run build"]
    end
  end
end
