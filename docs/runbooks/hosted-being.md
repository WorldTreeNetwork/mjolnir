# Hosted being (vibe-coder VM)

ADR 0011. Friend's C2 identikey; the VM is a device. Preview talks to
prod `https://api.hypersigil.world`.

## Login

Set on the host:

```
MJOLNIR_AUTH_ISSUER=https://auth.identikey.me
MJOLNIR_AUTH_CLIENT_ID=mjolnir-term
MJOLNIR_AUTH_REDIRECT_URI=https://api.vm.worldtree.network/auth/callback
```

Register the same public PKCE client on identikey-core
(`IDENTIKEY_CLIENTS` JSON, `subject_type: public`). Passkey at
`/authorize` opens `/term/:id`. grok uses `XAI_API_KEY` in
`/run/mjolnir/` tmpfs, not OIDC.

Existing Keycloak `owner_id`s on mimir will not match an XID `sub`.

## Bootstrap

Inside a spawned `ubuntu-24.04` guest:

```
curl -fsSL https://raw.githubusercontent.com/identikey/mjolnir/main/scripts/hosted-being-bootstrap.sh | bash
# or copy scripts/hosted-being-bootstrap.sh in via exec
```

Vite: `bun run dev --host` from `/root/hypersigil-store-frontend`.
`mj url` is the ticket preview. CORS for that origin is
`update-hypersigil-store-cors` (not this landing).

## Git key

`Mjolnir.GitSigning.put/2` then boot injects
`/run/mjolnir/git_signing_key`. Forgejo write registration is
`add-honor-git-remote`.
