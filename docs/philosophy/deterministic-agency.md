# Deterministic agency

**Status:** Position. Not an ADR. Not a SHALL.
**Date:** 2026-08-26
**Companion capture:** `~/work/IdentiKey/Papyrus/docs/notes/2026-08-26-ultimate-hammer.md`

If a neural network is a universal function approximator, Mjolnir is
the deterministic portion of the AI agent's agency.

---

A network approximates. It maps observation to a proposed next
action. Sampling is not replay. Weights are not an audit log. That
is the right job for a universal approximator and the wrong job for
the part of agency you need to *keep*.

Agency is the ability to change the world, to be messaged later, to
be bounded, to be restored. That part has to be deterministic:

| Move | Where it lives |
|---|---|
| Propose | the network (stochastic, approximate) |
| Act | a Linux microVM: files, processes, net, exec |
| Persist | BTRFS snapshot (disk today; memory soon) |
| Communicate across time or hosts | mailbox spool (ADR 0006) |
| Bound what may be done | capability tokens (Biscuit) |
| Address | VM identity, not a process handle |

The approximator lives *inside* a body, or talks *to* one. It is not
the body. Grok Build's current ultimate tool is a browser because a
browser is a deterministic action surface the network can operate.
Mjolnir is the general form of that surface: any size, any
filesystem snapshot, soon any memory snapshot, any of them running
an agentic loop.

Process calculus is the upgrade of linear lambda calculus to
imperfect information over communicating processes. The mailbox is
how that is emulated. The snapshot is how a process survives time.
The capability is how agency is delegated without sharing the
owner.

What this rules out: treating the model as the actor; treating a
chat log as the source of truth for what happened; treating tool
calls as side effects of sampling rather than commits to a body
that can be snapshotted, messaged, and attenuated.
