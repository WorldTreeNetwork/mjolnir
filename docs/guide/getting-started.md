# Getting Started: Your First Virtual Shell

This is a hands-on, type-along walkthrough. By the end you'll have spawned a real Linux
microVM, run commands in it, disconnected and reconnected without losing your work, and cleaned
it up. No prior Mjolnir knowledge assumed — just a working `mj` CLI pointed at a server.

> **What you're actually doing:** every `mj spawn` boots a genuine Linux virtual machine (its
> own kernel, hardware-isolated via KVM) on the Mjolnir server, in well under a second. It is
> not a container. When you "connect," you get a real terminal (PTY) into that machine. See
> [Coming from Docker](coming-from-docker.md) if that framing is new to you.

---

## 0. One-time setup

You need the `mj` CLI installed and signed in. If you haven't installed it, download the
archive for your platform from
[GitHub Releases](https://github.com/WorldTreeNetwork/mjolnir/releases):

```bash
tar xzf mj-<target>.tar.gz
sudo install -m 755 mj /usr/local/bin/mj
```

No archive for your platform? Build from the repo (needs Rust):

```bash
./scripts/build-client.sh --install    # installs `mjolnir` and the short `mj` alias
```

Then sign in. A browser opens on the IdentiKey sign-in page: approve with your passkey, or
choose **Create an account** there if you don't have one (a passkey, no username or email).
The token is saved in your OS config directory, so you only do this once:

```bash
mj login
```

With no flags, `mj` uses the default server, `https://api.vm.worldtree.network`. To use
another one, name it once: `mj login --api https://mjolnir.example.com`.

Check it worked:

```bash
mj status
# Shows your API endpoint, where the config and token live, and `Status: active`.
```

> Don't have a server? [Run a node](run-a-node.md) (mini-PC, AGPL host) or the README's
> [Run your own server](../../README.md#run-your-own-server) section. The VMs need Linux + KVM,
> so the *server* must be a Linux host — but the `mj` CLI itself is MIT and runs fine from a Mac.
>
> `mj connect` is a real PTY into the guest. `mj connect --session NAME` attaches tmux so
> reconnects (and extra humans) share one terminal. Secrets you set with `mj secrets` land
> as env vars inside the VM and never enter a snapshot.

---

## 1. Spawn a VM and drop straight into it

The fastest way to see Mjolnir work is to spawn *and* connect in one command:

```bash
mj spawn --connect
```

You'll see a few status lines while the VM boots, then your prompt changes — you're now
**inside the VM**:

```
Using SSH key: /home/you/.ssh/id_ed25519.pub
Spawning VM...
VM:           7Zk3mQ9xVbR2nLpW5tYc8H
<ticket>
💾 Persist interval: 250ms
Connecting to VM...
Connected. Opening shell...
root@mjolnir-vm:~#
```

That `root@mjolnir-vm:~#` prompt is a real root shell inside a fresh Linux machine. The `VM:`
line is the VM's ID; the line after it is its Iroh ticket. If you have a public key at
`~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`, `mj spawn` sends it so the VM accepts that key.

---

## 2. Type commands and watch them run

This is just a Linux box. Try it:

```bash
uname -a                      # confirm you're in a VM with its own kernel
whoami                        # root
cat /etc/os-release           # the guest distro (e.g. Ubuntu 24.04)
apt-get update && apt-get install -y cowsay   # yes, you have full apt + root
cowsay "I am a microVM"
```

Everything runs *inside the VM*, isolated from the host and from every other VM. You can break
things freely — install packages, edit system files, run a server. It's yours.

---

## 3. Disconnect — without destroying the VM

Here's the important mental model: **the terminal connection and the VM are two different
things.** Leaving the terminal does *not* stop the machine.

To end your shell session, just exit the shell:

```bash
exit          # or press Ctrl-D
```

You're back on your local machine. **The VM is still running on the server** — your installed
packages, running processes, and files are all still there. You only closed the *window into*
it.

To prove it, list your VMs:

```bash
mj list
```

```
NAME   STATE     IP             SHELL   ID                       TICKET
-      running   10.192.0.12    ready   7Zk3mQ9xVbR2nLpW5tYc8H   <ticket>
```

There it is, still running. Note the `ID` column — you'll use it to reconnect.

---

## 4. Reconnect to the running VM

Connect again using the VM ID from `mj list`:

```bash
mj connect 7Zk3mQ9xVbR2nLpW5tYc8H
```

You're back in the same machine. Run `cowsay moo` — `cowsay` is still installed, because the VM
never stopped.

> **Two ways to connect:**
> - `mj connect <vm_id>` — over a WebSocket PTY (goes through the server's API).
> - `mj connect <ticket>` — peer-to-peer over [Iroh](https://iroh.computer) QUIC, which
>   traverses NATs with no port-forwarding. The *ticket* is the string `mj spawn` printed to
>   stdout. For scp/sftp/VS Code, use `mj proxy` as an OpenSSH `ProxyCommand`.

---

## 5. Durable sessions: survive disconnects *mid-command*

A plain `mj connect` gives you a shell, but if you're running something long (a build, a
training job) and your connection drops, the foreground process can be interrupted. For
work you want to *detach from and come back to*, start a named session:

```bash
mj connect 7Zk3mQ9xVbR2nLpW5tYc8H --session work
```

This runs `tmux` inside the VM under the name `work`. Now you can:

- **Detach** any time with `Ctrl-B` then `D` — your processes keep running inside the VM.
- **Reattach** later by reconnecting with the *same* session name:
  ```bash
  mj connect 7Zk3mQ9xVbR2nLpW5tYc8H --session work
  ```
  …and you're right back where you left off, mid-build, output and all.

This is the recommended way to run anything long-lived.

---

## 6. Run one-off commands without an interactive shell

Sometimes you don't want a terminal — you just want to run a command and get the output back.
That's `mj exec`:

```bash
mj exec 7Zk3mQ9xVbR2nLpW5tYc8H "ls -la /"
mj exec 7Zk3mQ9xVbR2nLpW5tYc8H "python3 --version"
```

`exec` accepts a VM ID *or* an Iroh ticket. It's perfect for scripting against a VM.

---

## 7. Clean up

When you're done with a VM, destroy it:

```bash
mj kill 7Zk3mQ9xVbR2nLpW5tYc8H
```

This stops the microVM and deletes its copy-on-write filesystem. **Anything you didn't snapshot
is gone.** That's by design — VMs are cheap and disposable.

> Want to *keep* the state — your installed tools, your configured environment — so you can
> spin up fresh VMs from it later? That's exactly what snapshots are for. Read on:
> **[Working with Snapshots](snapshots.md).**

---

## Command cheat sheet

| Goal | Command |
|---|---|
| Authenticate (once) | `mj login` |
| Spawn + connect immediately | `mj spawn --connect` |
| Spawn (prints an Iroh ticket) | `mj spawn` |
| List your VMs | `mj list` |
| Details on one VM | `mj info <vm_id>` |
| Interactive shell (WebSocket) | `mj connect <vm_id>` |
| Durable, reattachable shell | `mj connect <vm_id> --session <name>` |
| Interactive shell (P2P) | `mj connect <ticket>` |
| Run a one-off command | `mj exec <vm_id> "<cmd>"` |
| Snapshot a running VM | `mj snapshot create <vm_id> <name>` |
| Spawn from a snapshot | `mj spawn --snapshot <name>` |
| Spawn with a public UDP port | `mj spawn --publish-udp 20001:4433` — [details](#publishing-a-udp-port) |
| Destroy a VM | `mj kill <vm_id>` |
| Deploy a web app (service VM) | `mj deploy . --name <app>` — [guide](deploying-an-app.md) |
| Merge host-escrowed env (then redeploy) | `mj secrets set <app> KEY` |

Run `mj --help` for the complete surface.

## Publishing a UDP port

A guest has a private address. To let the internet reach a UDP service in it
(a QUIC server, a game server, a Media-over-QUIC relay), publish a port when
you spawn:

```bash
mj spawn --publish-udp 20001:4433     # host UDP 20001 -> guest UDP 4433
mj spawn --publish-udp 20001          # same port on both sides
mj spawn --publish-udp 20001 --publish-udp 20002:9000
```

The host forwards in the kernel (DNAT). There is no proxy in the path. QUIC
puts every connection on one UDP port, so one published port serves a whole
QUIC service. `mj info <vm_id>` shows what is published and at which host
address:

```
Published Ports
───────────────────────────────────────────────────────
udp 203.0.113.7:20001 -> 10.200.41.9:4433
```

In the guest, listen on the guest port on all addresses or on the guest IP.
From another machine: `echo hi | nc -u -w1 203.0.113.7 20001`.

The ports stay with the VM. They come back after a restart of the VM or of
the host service, and they are released by `mj kill`. They cannot be changed
on a running VM; spawn again (from a snapshot, if you need the disk).

What the server refuses, before it starts anything:

| Response | Meaning |
|---|---|
| `403 published_ports_disabled` | This host has not enabled publishing. |
| `403 host_port_not_permitted` | The host port is outside the host's range (the response gives the range). |
| `403 host_port_reserved` | The host keeps that number for itself. |
| `409 host_port_published` | Another VM holds it, running or stopped. |
| `409 host_port_bound_by_host` | A process on the host is using that UDP port. |

Limits: UDP only, IPv4 only, at most four ports per VM. The published address
is not reachable from inside a guest on the same host. If the host sits
behind a provider firewall, that firewall must also allow the port.

**Host operators:** publishing is off until you set a range in
`/etc/mjolnir/env` and restart the service:

```
MJOLNIR_PUBLISHED_PORT_RANGE=20000-20099
# MJOLNIR_PUBLISHED_PORT_INTERFACE=enp1s0   # default: the default-route interface
```

Once set, anyone who may spawn on the host may publish inside the range.
Keep it below 32768, where the kernel picks ports for the host's own outgoing
sockets. To see the rules: `iptables -t nat -S PREROUTING | grep publish:`.

`mj spawn` is a throwaway shell. It does **not** read the deploy-secrets file.
A store or API that needs `DATABASE_URL` / Stripe / SES is a different spawn:
`mj deploy` boots a **service VM** and injects host-escrowed env at start.
Set those keys with `mj secrets`, then deploy — **[Deploying a Web App](deploying-an-app.md)**.

---

## Next steps

- **[Working with Snapshots](snapshots.md)** — save a VM's state and spin up new VMs from it.
- **[Deploying a Web App](deploying-an-app.md)** — `mj deploy`, `mj secrets`, `mj domain`.
- **[Host sidecars](host-sidecars.md)** — blob store, API, and Postgres on `10.200.0.1`;
  locators in `/etc/mjolnir/vm.json`.
- **[Coming from Docker](coming-from-docker.md)** — the conceptual map if you think in containers.
- [README](../../README.md) — install, server setup, and the full CLI reference.
