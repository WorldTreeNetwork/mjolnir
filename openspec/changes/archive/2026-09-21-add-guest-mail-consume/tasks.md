# Tasks — add-guest-mail-consume

- [x] Default consume loop in mjolnir-agent: peek, fsync-record id, dispatch, ACK
- [x] Seen-id file: redelivery of a recorded id ACKs without re-dispatch
- [x] POST /done still 409 while inbox unacked
- [x] Guest POST /send passes producer id through to Mailbox.accept
- [x] Tests: seen-store idempotency; Elixir send_message forwards id
