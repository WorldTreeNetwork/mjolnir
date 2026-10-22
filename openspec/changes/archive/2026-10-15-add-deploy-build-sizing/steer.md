# Steer — add-deploy-build-sizing

2026-09-30, Duke (intend DAG `mjolnir-al1j`, node `mjolnir-pjjz`):

- Activated.
- Memory alone did not stop the build-VM stall (8 GB also stalled); the
  stall is `mjolnir-mne7`, diagnosed under node `mjolnir-af5y`. This
  change is still owed for 2-vCPU starvation and the per-app knob.
- Sequence after (or before) `add-deploy-step-inputs`; not in parallel.
