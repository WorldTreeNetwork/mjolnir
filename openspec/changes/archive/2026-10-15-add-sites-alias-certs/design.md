# Design

Mechanism for ADR 0013. The living spec is the behavior. This file is how the issuer matches the gateway without a new control call.

## Alias index

`SecretStore.read_alias/1` returns `{:ok, {fp, site}}`, `:not_found`, or `{:error, reason}`.

- `:enoent` and `ArgumentError` from `validate_fqdn!/1` are `:not_found`.
- `parse_alias_index/1` returning `:error` is `{:error, :unreadable}`. Do not change that parser. `"fp:site"` stays a legacy hit. `"%%%"` is unreadable.
- Any other `File.read` error, including `:eisdir`, is `{:error, reason}`.

`lookup_alias/1` calls `read_alias/1` and maps `{:error, _}` to `:not_found`. Host-header callers stay miss-on-error.

## Classify

`Mjolnir.Gateway.Classify` reads the base toml (`:gateway_toml_path`, default `/etc/mjolnir/gateway.toml`) and `[[route]]` / `[[alias]]` from the sibling `gateway.d/*.toml` (or `GATEWAY_CONFIG_D` on the production path). Tests pin the path with the process dictionary so a developer machine cannot change the suite.

- Missing base file: no apexes, `:reject`. Issuance may continue.
- Other base read error, invalid fallthrough, wildcard suffix, or a `[[domain]]` whose suffix cannot be read: `{:error, :gateway_config_unreadable}`.
- Missing fallthrough is `:iroh`. Duplicate suffix keeps the first.
- A `[[alias]]` resolves under any fallthrough. A bad z32 node, an orphan apex, or a bad route backend is skipped, matching the gateway loader.
- Bare apex with no empty-subdomain route is `:reject`, except `parked`, which is `:parked`.
- Longest suffix wins. Strip a trailing `:port`. A `[[cert]]` does not create an apex.
- A drop-in that fails to read is skipped. Drop-ins cannot add apexes.

`Local` and `Iroh` are the 409. `Reject` and `Parked` issue.

## Install and renewal

`Gateway.Certs.ensure/2` grows `domain:`, default `true`. `false` skips `ensure_domain_block` after the cert block. The unchanged short-circuit still adds nothing.

`ops.ensure` is 4-arity `(fqdn, cert, key, opts)`. `issue/2` defaults `domain: true`. Site issue and every renewal pass `domain: false`. Renewal checks the alias index before `issue_cmd`: an app host skips the index; any other host with `{:error, _}` returns `{:error, :alias_index_unreadable}` and does not call Let's Encrypt. A hit or a missing file still reinstalls. Renewal does not classify and does not re-apply the 409.

`Application.get_env(:mjolnir, :cert_ops)` is merged when the caller does not pass `:ops`, so router tests do not shell out. Production does not set it. Call opts win over the env.

## List

`GET /api/certs` still omits PEMs. The operator sees every cert. Anyone else sees owned app domains plus hosts whose `read_alias/1` is `{:ok, _}`. Any other alias result omits that host and the list stays 200.

## Do not

Do not edit `config/config.exs`, `config/test.exs`, `config/runtime.exs`, ADR 0012, or the auth / forgejo / git-signing files. Those leases are held. Do not fix `mjolnir-5ckn` here. Do not deploy. Do not restart `mjolnir.service`.
