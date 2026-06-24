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

You need the `mj` CLI installed and pointed at a Mjolnir server. If you haven't installed it:

```bash
# From the repo (needs Rust). Installs `mjolnir` and the short `mj` alias.
./scripts/build-client.sh --install
```

Then authenticate. This saves your server URL and token to `~/.config/mjolnir/`, so you only do
it once:

```bash
mj login --api https://mjolnir.example.com
```

Check it worked:

```bash
mj status
# Shows your current API endpoint and that you're authenticated.
```

> Don't have a server? See the README's [Run your own server](../../README.md#run-your-own-server)
> section. The VMs need Linux + KVM, so the *server* must be a Linux host — but the `mj` CLI
> itself runs fine from a Mac.

---

## 1. Spawn a VM and drop straight into it

The fastest way to see Mjolnir work is to spawn *and* connect in one command:

```bash
mj spawn --connect
```

You'll see a few status lines while the VM boots, then your prompt changes — you're now
**inside the VM**:

```
Spawning VM...
Waiting for shell...
💾 Persist interval: 5000ms
Connected. PTY session active.
root@mjolnir:~#
```

That `root@mjolnir:~#` prompt is a real root shell inside a fresh Linux machine.

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
VM ID                                  STATUS    MEMORY
a1b2c3d4-...-...                        running   512 MB
```

There it is, still running. Note that VM ID — you'll use it to reconnect.

---

## 4. Reconnect to the running VM

Connect again using the VM ID from `mj list`:

```bash
mj connect a1b2c3d4-...-...
```

You're back in the same machine. Run `cowsay moo` — `cowsay` is still installed, because the VM
never stopped.

> **Two ways to connect:**
> - `mj connect <vm_id>` — over a WebSocket PTY (goes through the server's API).
> - `mj connect <ticket>` — peer-to-peer over [Iroh](https://iroh.computer) QUIC, which
>   traverses NATs with no port-forwarding. The *ticket* is the string `mj spawn` printed to
>   stdout. `mj ssh <ticket>` gives you a real SSH session the same way.

---

## 5. Durable sessions: survive disconnects *mid-command*

A plain `mj connect` gives you a shell, but if you're running something long (a build, a
training job) and your connection drops, the foreground process can be interrupted. For
work you want to *detach from and come back to*, start a named session:

```bash
mj connect a1b2c3d4-...-... --session work
```

This runs `tmux` inside the VM under the name `work`. Now you can:

- **Detach** any time with `Ctrl-B` then `D` — your processes keep running inside the VM.
- **Reattach** later by reconnecting with the *same* session name:
  ```bash
  mj connect a1b2c3d4-...-... --session work
  ```
  …and you're right back where you left off, mid-build, output and all.

This is the recommended way to run anything long-lived.

---

## 6. Run one-off commands without an interactive shell

Sometimes you don't want a terminal — you just want to run a command and get the output back.
That's `mj exec`:

```bash
mj exec a1b2c3d4-...-... "ls -la /"
mj exec a1b2c3d4-...-... "python3 --version"
```

`exec` accepts a VM ID *or* an Iroh ticket. It's perfect for scripting against a VM.

---

## 7. Clean up

When you're done with a VM, destroy it:

```bash
mj kill a1b2c3d4-...-...
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
| Authenticate (once) | `mj login --api <url>` |
| Spawn + connect immediately | `mj spawn --connect` |
| Spawn (prints an Iroh ticket) | `mj spawn` |
| List your VMs | `mj list` |
| Details on one VM | `mj info <vm_id>` |
| Interactive shell (WebSocket) | `mj connect <vm_id>` |
| Durable, reattachable shell | `mj connect <vm_id> --session <name>` |
| Interactive shell (P2P) | `mj connect <ticket>` |
| SSH into the VM (P2P) | `mj ssh <ticket>` |
| Run a one-off command | `mj exec <vm_id> "<cmd>"` |
| Snapshot a running VM | `mj snapshot <vm_id> <name>` |
| Spawn from a snapshot | `mj spawn --snapshot <name>` |
| Destroy a VM | `mj kill <vm_id>` |

Run `mj --help` for the complete surface.

---

## Next steps

- **[Working with Snapshots](snapshots.md)** — save a VM's state and spin up new VMs from it.
- **[Coming from Docker](coming-from-docker.md)** — the conceptual map if you think in containers.
- [README](../../README.md) — install, server setup, and the full CLI reference.
