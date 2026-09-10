# Tasks

- [x] UDP listen (config host/port); unset = no bind
- [x] Register Listener on vsock ch2; multi-VM sender id
- [x] JSON MSG + `schema` → `:app_log`; else `:vm_syslog`
- [x] 64 KiB max; oversize malformed raw, not silent drop
- [x] `:app_log` default sinks `[:eventbus]`
- [x] `mix test test/mjolnir/syslog/`
