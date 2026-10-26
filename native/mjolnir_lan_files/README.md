# LAN files guest

This is a guest executable, not a host NIF. Install it inside the persistent
share guest. Create `/var/lib/mjolnir` on that guest's subvolume, then run with
`LAN_FILES_BIND=<guest-TAP-IPv4>:8080`. `LAN_FILES_METADATA` defaults to
`/var/lib/mjolnir/lan-files.sqlite`; retain the database and its WAL together.
Canonical bytes use only `http://10.200.0.1:7222/storage/blob/b3/<base58-hash>`.
The host blob-door configuration is unchanged.

Wire flow:

1. GET `/challenge` returns identikey-auth canonical CBOR (60 second TTL).
2. The client answers with its Ed25519 signer and puts standard base64 of
   `Response::to_bytes()` in `X-Identikey-Response` on each PUT or GET.
   Every request needs a new challenge. Audience is `mjolnir:lan-files:v1`.
3. PUT `/files/<base58-Blake3>` carries the encrypted bytes (64 MiB bound).
   HTTP 201 means door acknowledgement and durable ownership. Retry with a
   fresh proof after failure; there is no rollback DELETE and no server session.
4. For GET of the same path, also send `X-Recrypt-Capability`: standard base64
   of `Capability::sign()` bytes signed by the first putter's Ed25519 key.
   Use File, the exact hash, `Blake3(raw holder public key)`, read, and the
   owner's raw-key fingerprint as issuer. Delegation parents are refused.
   The service persists accepted signed caps; the client retains its cap and
   recryption key. No signing or recryption private key is sent to the server.
   Classical signatures are accepted; a present PQ signature must verify.

Host config (publication reconciles on boot/attach):

```elixir
config :mjolnir, :lan_files, %{
  vm_id: "<share VM id>", interface: "enp3s0", publish_port: 7443, http_port: 8080
}
```

The VM host process polls the named interface once a second, reconciles scoped
DNAT/FORWARD rules, and removes them on stop, target change, or address loss.
There is no host listening socket and port 7222 is never published. No live
rules or service changes are made by the unit tests. Second-host LAN verification
remains deployment work.

Set `MJOLNIR_LAN_FILES_BIN` to the host path of the compiled guest executable
and `MJOLNIR_LAN_FILES` to `vm_id,interface,publish_port,http_port`. Exactly
four fields are required; both ports must be in 1..65535 and neither may be
7222. The boot config reads those variables. The defaults are nil, so an
unconfigured host installs and publishes nothing.

On fresh boot and resume, after the TAP address is known and before the guest
starts, the host copies the binary to `/usr/local/bin/mjolnir-lan-files`, creates
the metadata directory, and refreshes a service enabled through
`basic.target.wants`. The unit binds the current guest IPv4 and HTTP port,
retains `/var/lib/mjolnir/lan-files.sqlite`, and retries every two seconds
without a start limit until the guest agent assigns the address. A missing
binary or a different VM skips installation.

## Source provenance

The build uses sibling source checkouts under `work/IdentiKey`, with revisions
verified and embedded by `build.rs`, and printed by the executable on startup:

- identikey-protocol / identikey-auth: `8cd455c7308e86c50a0b338b82c7d8e814b4b96e`
- recrypt / recrypt-storage-auth and recrypt-core: `0be9ed9a56bf4d7fd846e0c923980471dec88526`

Tracked modifications or a different HEAD fail the build. These local path
dependencies require those clean sibling checkouts to reproduce this build;
they are deliberately recorded rather than claiming an untested remote pin.
The upstream storage-auth dependency enables recrypt-core's native crypto
features, so its OpenFHE/liboqs build prerequisites also apply here.

The native workspace patches bindgen 0.71.1 with the upstream Clang 22+ type
completeness fix required by oqs-sys 0.11. See
[`vendor/bindgen/PATCH.md`](vendor/bindgen/PATCH.md) for provenance and removal
conditions. The liboqs source remains in the upstream oqs-sys dependency;
recrypt-storage-auth and the `PqOptional` verification policies stay enabled.
