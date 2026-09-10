# Restore the B0 Buzz hive from snapshot

The running hive is VM `buzz-relay` (`Deploy.Registry` app name).
Filesystem snapshot `buzz-relay-b0` (and later named snapshots) is
the backup. `mj freeze` is not.

Managed secrets (`secrets_mode: managed`) escrow the LUKS passphrase
at `/var/lib/mjolnir/escrow/<vm_id>`. That path is **off** the VM
subvolume. `mj spawn --snapshot` mints a **new** UUID, so an escrow
HIT on restore is same-id dormancy wake only.

## Before `mj kill`

1. `mj snapshot create <vm_id> buzz-relay-<date>` (crash-consistent:
   guest sync → pause → btrfs snapshot → resume).
2. Copy `/var/lib/mjolnir/escrow/<vm_id>` to a dated file. `mj kill`
   deletes the escrow.

## Restore onto a new VM id

```
# as root on the hypervisor
OLD=<old-vm-uuid>
NEW will be printed by spawn

mj spawn --snapshot buzz-relay-<date> --memory 4096
# note NEW uuid
cp /root/escrow-keep/$OLD /var/lib/mjolnir/escrow/$NEW
chmod 600 /var/lib/mjolnir/escrow/$NEW
# if the guest still has secrets.luks and the passphrase is the copied one,
# the next boot opens it. If spawn already generated a fresh passphrase,
# remove var/lib/mjolnir/secrets.luks from the restored subvolume and
# re-supply secrets at spawn instead.
```

Then re-adopt: `PUT /api/apps/buzz-relay` with the new `service_vm_id`
(or `mj app adopt` once that CLI is on PATH). `mj domain set` if the
registry row was rebuilt. Do not `mj deploy buzz-relay` — cutover
empties the hive.

Join URL stays `wss://buzz.identikey.me` as long as DNS and the cert
still point at this host.
