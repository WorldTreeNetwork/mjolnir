# Tasks

- [ ] Confirm H1 against the pinned moq grant matcher. Record the exact publish and subscribe pattern strings the mint will emit.
- [ ] Add scope `relay:join` for user JWTs only. Sites tokens and the operator socket do not receive it.
- [ ] Root-only mint key directory `/var/lib/mjolnir/relay-mint/` and `scripts/relay-mint-key.sh` implementing the rotation steps.
- [ ] `POST /api/relay/rooms/:room/participants/:participant/token` requiring `relay:join` and canonical `x-owner-id`. Returns the token, expiry, root, publish, subscribe, and `relay_host`. No key material.
- [ ] Refuse a room or participant segment outside the segment rule before signing.
- [ ] Sign with `current.jwk` only. Public set written by rename to `/etc/mjolnir-relay/relay-keys.json`.
- [ ] Tests: tokenless client refused on both transports; token for another room refused on both; valid token subscribes and publishes its own track on both; the same token publishing the other participant's path refused on both.
- [ ] Tests: missing scope is 403; bad `x-owner-id` is 400; body `owner_id` does not change the root; private key is not in the key file and is mode `0600` root.
- [ ] Tests: after the public set drops the previous key, a new session with the old key is refused, and a session admitted under the old key is still up until `exp`.

Out of scope stays in the proposal. Those lines are not tasks.
