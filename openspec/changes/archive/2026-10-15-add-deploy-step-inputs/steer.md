# Steer — add-deploy-step-inputs

2026-09-30, Duke (intend DAG `mjolnir-al1j`, node `mjolnir-g0di`):

- Activated. Cheapest win first: command-only steps stop missing.
- Runs before `add-deploy-build-caches`, which depends on it.
- Shares `Deploy.Manifest` / `Deploy.Orchestrator` with
  `add-deploy-build-sizing`: sequence the two acts, do not fan out.
