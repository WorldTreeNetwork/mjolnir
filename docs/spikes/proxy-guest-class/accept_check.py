#!/usr/bin/env python3
"""Exact predicates for the proxy-guest acceptance command.

Fixtures run with no guest. The shell passes exec JSON files, never argv bodies.
"""
import json
import sys

HOST = "10.200.0.1"
RESOLVER = "127.0.0.1"


def die(msg):
    raise SystemExit(msg)


def load(path):
    with open(path) as fh:
        body = json.load(fh)
    if not isinstance(body, dict):
        die("inspection was not an object")
    if body.get("error"):
        die("inspection error")
    if body.get("exit_code") not in (None, 0):
        die("inspection exit %s" % body.get("exit_code"))
    if "output" not in body or not isinstance(body.get("output"), str):
        die("missing inspection")
    return body["output"]


def first_field_lines(text):
    out = []
    for line in text.splitlines():
        parts = line.split()
        if parts:
            out.append(parts[0])
    return out


def section(out, index):
    parts = out.split("---")
    if len(parts) <= index:
        die("missing section %s" % index)
    return parts[index]


def assert_no_default(route):
    if "default" in first_field_lines(route):
        die("default route present")


def assert_host(route):
    if HOST not in first_field_lines(route):
        die("host /32 missing")


def assert_no_host(route):
    if HOST in first_field_lines(route):
        die("host /32 still present")


def resolvers(text):
    found = []
    for line in text.splitlines():
        parts = line.split()
        if parts and parts[0] == "nameserver":
            if len(parts) != 2:
                die("malformed nameserver")
            found.append(parts[1])
    return found


def assert_resolver(text):
    if resolvers(text) != [RESOLVER]:
        die("resolver %s" % resolvers(text))


def unit_status(text):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines:
        die("missing unit status")
    return lines[-1]


def assert_unit_active(text):
    if unit_status(text) != "active":
        die("unit %s" % unit_status(text))


def assert_pin(out):
    assert_no_default(section(out, 0))
    assert_host(section(out, 0))
    assert_resolver(section(out, 1))
    assert_unit_active(section(out, 2))


def assert_wiped(out):
    assert_no_default(out)
    assert_no_host(out)


def assert_confinement(out):
    if "default" not in first_field_lines(section(out, 0)):
        die("confinement missing default route")
    lines = {line.strip() for line in out.splitlines()}
    if "JOIN_FAIL" in lines or "NO_CGROUP" in lines or "joined" not in lines:
        die("cgroup join failed")
    required = (
        "ROOT_LOOP OK",
        "ROOT_HOST OK",
        "ROOT_PUB OK",
        "ROOT_ALT OK",
        "UNIT_LOOP OK",
        "UNIT_HOST OK",
        "UNIT_PUB FAIL",
        "UNIT_ALT FAIL",
        "UNIT_V6 FAIL",
    )
    for line in required:
        if line not in lines:
            die(line)
    if "ROOT_V6 OK" in lines and "UNIT_V6 FAIL" not in lines:
        die("unit opened ipv6")


def assert_ordinary(out):
    if "default" not in first_field_lines(section(out, 0)):
        die("ordinary guest missing default route")
    names = resolvers(section(out, 1))
    if not any(item in {"8.8.8.8", "1.1.1.1"} for item in names):
        die("ordinary guest missing public resolver")


def assert_spawn(body):
    if body.get("state") != "running":
        die("spawn not running")
    if body.get("ticket") or body.get("iroh_addr"):
        die("spawn published a relay")


def assert_reboot(body):
    if body.get("ok") is not True or body.get("rebooted") is not True:
        die("reboot not complete")
    if body.get("guest_healthy") is not True:
        die("reboot unhealthy")


def assert_live(body, vm_id):
    if not isinstance(body, dict) or body.get("error"):
        die("missing resumed inspection")
    if body.get("id") != vm_id or body.get("state") != "running":
        die("resumed identity")
    if body.get("enable_iroh") is not False:
        die("resumed enable_iroh")
    if "ticket" not in body or "iroh_addr" not in body:
        die("resumed endpoint fields missing")
    if body.get("ticket") or body.get("iroh_addr"):
        die("resumed relay")


def assert_heal(body):
    rows = {c.get("name"): c for c in body.get("checks") or []}
    guest = rows.get("guest_network")
    if not guest:
        die("heal missing guest_network")
    state = (guest.get("status") or {}).get("state")
    if state != "dead":
        die("heal guest_network %s" % state)
    if guest.get("action") not in ("healed", ":healed"):
        die("heal action %s" % guest.get("action"))


def assert_state(path, vm_id, image, run_id):
    with open(path) as fh:
        record = json.load(fh)
    if record.get("uuid") != vm_id:
        die("state uuid mismatch")
    cfg = record.get("spawn_config") or {}
    if cfg.get("base_image") != image:
        die("state base_image")
    if cfg.get("enable_iroh") is not False:
        die("state enable_iroh")
    meta = record.get("metadata") or {}
    if meta.get("accept_run") != run_id:
        die("state not owned by this run")


def owned(path, run_id):
    try:
        with open(path) as fh:
            record = json.load(fh)
    except OSError:
        return False
    meta = record.get("metadata") or {}
    return meta.get("accept_run") == run_id


def payload(kind, run_id):
    if kind == "proxy":
        body = {
            "base_image": "proxy-guest-class-spike",
            "memory_mb": 1024,
            "vcpus": 2,
        }
    elif kind == "ordinary":
        body = {
            "base_image": "ubuntu-24.04",
            "memory_mb": 512,
            "vcpus": 1,
        }
    else:
        die("unknown payload")
    body.update(
        {
            "restart_policy": "never",
            "enable_iroh": False,
            "metadata": {"accept_run": run_id},
        }
    )
    return body


def expect_fail(fn):
    try:
        fn()
    except SystemExit:
        return
    die("fixture accepted a broken observation")


def fixtures():
    good = (
        "10.200.0.1 dev eth0 scope link\n"
        "---\nnameserver 127.0.0.1\n---\nactive\n"
    )
    assert_pin(good)
    expect_fail(lambda: assert_pin(
        "10.200.0.10 dev eth0 scope link\n---\nnameserver 127.0.0.1\n---\nactive\n"
    ))
    expect_fail(lambda: assert_pin(
        "10.200.0.1 dev eth0 scope link\n---\nnameserver 127.0.0.1\nnameserver 9.9.9.9\n---\nactive\n"
    ))
    expect_fail(lambda: assert_pin(
        "10.200.0.1 dev eth0 scope link\n---\nnameserver 127.0.0.1\n---\ninactive\n"
    ))
    expect_fail(lambda: load_obj({"exit_code": 3, "stderr": "inactive"}))
    expect_fail(lambda: assert_wiped("10.200.0.1 dev eth0 scope link\n"))
    expect_fail(lambda: assert_reboot({"ok": True}))
    expect_fail(lambda: assert_reboot({"ok": True, "rebooted": False, "guest_healthy": False}))
    assert_reboot({"ok": True, "rebooted": True, "guest_healthy": True})
    good_live = {
        "id": "vm-1",
        "state": "running",
        "enable_iroh": False,
        "ticket": None,
        "iroh_addr": None,
    }
    assert_live(good_live, "vm-1")
    expect_fail(lambda: assert_live({"error": "not_found"}, "vm-1"))
    expect_fail(lambda: assert_live({**good_live, "ticket": "present"}, "vm-1"))
    print("fixtures ok")


def load_obj(body):
    if body.get("error"):
        die("inspection error")
    if body.get("exit_code") not in (None, 0):
        die("inspection exit")
    if "output" not in body:
        die("missing inspection")
    return body["output"]


def main(argv):
    mode = argv[1]
    if mode == "fixtures":
        fixtures()
        return
    if mode == "payload":
        print(json.dumps(payload(argv[2], argv[3])))
        return
    if mode == "owned":
        path, run_id = argv[2], argv[3]
        if not owned(path, run_id):
            die("not owned")
        return
    if mode == "pin":
        assert_pin(load(argv[2]))
        return
    if mode == "confinement":
        assert_confinement(load(argv[2]))
        return
    if mode == "wiped":
        assert_wiped(load(argv[2]))
        return
    if mode == "ordinary":
        assert_ordinary(load(argv[2]))
        return
    if mode == "spawn":
        with open(argv[2]) as fh:
            assert_spawn(json.load(fh))
        return
    if mode == "reboot":
        with open(argv[2]) as fh:
            assert_reboot(json.load(fh))
        return
    if mode == "live":
        with open(argv[2]) as fh:
            assert_live(json.load(fh), argv[3])
        return
    if mode == "heal":
        with open(argv[2]) as fh:
            assert_heal(json.load(fh))
        return
    if mode == "state":
        assert_state(argv[2], argv[3], argv[4], argv[5])
        return
    die("unknown mode")


if __name__ == "__main__":
    main(sys.argv)
