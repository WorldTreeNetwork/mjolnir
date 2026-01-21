# Exclude integration tests by default (require KVM)
ExUnit.configure(exclude: [:integration])
ExUnit.start()
