# Exclude by default:
#   :integration — need KVM + root, run on server only
#   :e2e         — future full-stack tests
#   :chaos       — mutate a live Mjolnir host; opt-in via `mix test --only chaos`
#   :destructive — subset of chaos that cause observable host downtime
ExUnit.configure(exclude: [:integration, :e2e, :chaos, :destructive])
ExUnit.start()
