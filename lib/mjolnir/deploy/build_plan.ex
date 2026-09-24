defmodule Mjolnir.Deploy.BuildPlan do
  @moduledoc """
  Describes the full plan for building and running a detected app.

  Produced by `Mjolnir.Deploy.Detector` and consumed by `Mjolnir.Deploy.Builder`.
  Fields are intentionally flat and serialisable — no functions, no closures.
  """

  use TypedStruct

  typedstruct enforce: true do
    @typedoc """
    A fully-resolved build plan.

    - `runtime` — mise-managed runtime spec, e.g. `"node@20"`.
    - `package_manager` — detected from lockfile; drives install/build commands.
      `nil` for manifest-declared apps (`Mjolnir.Deploy.Manifest`), which state
      their build steps outright and so need no Node package-manager inference.
    - `steps` — ordered shell commands that build the app. Run sequentially;
      each step is a candidate snapshot boundary.
    - `start_command` — command the service VM executes to start the app.
    - `port` — port the app binds on inside the VM.
    - `base_image` — optional `@base/` name from `mjolnir.toml`. `nil` for
      inferred SvelteKit apps so Orchestrator keeps `deploy-node-bun`
      (mjolnir-6ee1). A set value is used unless `mj deploy --base` / rpc
      `:base_image` overrides it.
    """
    field(:runtime, String.t())
    field(:package_manager, :npm | :bun | :pnpm | :yarn | nil)
    field(:steps, [String.t()])
    field(:start_command, String.t())
    field(:port, pos_integer())
    field(:base_image, String.t() | nil, default: nil)
  end
end
