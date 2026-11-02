# steer add-guest-fence-host

**When.** 2026-11-01
**Depth.** standard

## Decided
- fence-channel: Spike before act (user)
  Why: The fourth review already accepted the host-fence contract. The channel is still unverified. Act stays blocked until a finding says go or the line is skipped. This reaffirms the 2026-10-31 choice.

## Skipped
- (none)

## Feeds change
The fence-channel line stays open and unverified. Do not pick a transport or a storage engine. Do not treat this as permission to act. The accepted contract stands: identity, instance handle, and generation come from the authenticated channel, and commit stays ordered with transfer and revocation. Change should not invent a new contract from this pass. The spike line stays `unverified`, not `go` or `skipped`.

Spike 2026-11-01 returned go. See docs/spikes/fence-channel/finding.md. The line is no longer unverified. The finding still does not pick a transport or a storage engine, and it is not the host implementation.
