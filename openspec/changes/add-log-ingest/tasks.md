# Tasks

- [ ] UDP listen (config host/port); unset = no bind
- [ ] Register Listener on vsock ch2; multi-VM sender id
- [ ] JSON MSG + `schema` → `:app_log`; else `:vm_syslog`
- [ ] 64 KiB max; oversize malformed raw, not silent drop
- [ ] `:app_log` default sinks `[:eventbus]`
- [ ] `mix test test/mjolnir/syslog/`
