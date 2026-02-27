import Config

config :logger, level: :info

config :mjolnir,
  guest_agent_bin: "/opt/mjolnir/native/target/x86_64-unknown-linux-musl/release/mjolnir-agent"
