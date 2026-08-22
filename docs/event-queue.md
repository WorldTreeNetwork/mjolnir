
The most robustly stress tested event queue that exists is email. Spam has made it so that we have email providers which can handle extremely large load. It has support for multiple namespaces. It has authority for resolving those namespaces, DNS.

The mailbox argument that follows from this (fsync spool before 200,
one file per message, bounce on give-up, compose 0MQ above the spool)
is [`philosophy/mailbox-as-spool.md`](philosophy/mailbox-as-spool.md). 

xvfb === golden ticket - once you get a display you get the ability to pass a stream.  A stream is an event queue. (UART)


capn proto / durable objects - leave an imprint of the interface ..... and teleport there.
It is the secret to pi channels. just leave 4 pins of a uart out there.
