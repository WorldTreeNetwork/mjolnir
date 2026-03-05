# Exclude integration tests by default (require KVM)
ExUnit.configure(exclude: [:integration, :e2e])
ExUnit.start()
