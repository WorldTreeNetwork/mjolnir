#!/usr/bin/env bash
# Drive scripts/deploy.sh against a local fixture. No production SSH.
# systemctl restart mjolnir kills the fixture guest the way a node restart
# kills Port-owned hypervisors. A stub that ignores that restart fails the
# cutover proof below.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${DEPLOY_TEST_SCRATCH:-/tmp/grok-goal-ab910927b6f1/implementer}"
ELIXIR="${ELIXIR:-$(ls -d "$HOME"/.local/share/mise/installs/elixir/*/bin/elixir 2>/dev/null | sort | tail -1)}"
ELIXIRC="${ELIXIRC:-${ELIXIR%/elixir}/elixirc}"
ELIXIR_BIN="$(dirname "$ELIXIR")"
ERL_BIN="$(ls -d "$HOME"/.local/share/mise/installs/erlang/27.*/bin 2>/dev/null | sort | tail -1)"

run_twice() {
    local label="$1" logfile="$2"
    local n
    for n in 1 2; do
        echo "===== $label run $n =====" | tee -a "$logfile"
        run_one "$label" "$logfile"
        echo "===== $label run $n PASS =====" | tee -a "$logfile"
    done
}

run_one() {
    local label="$1" logfile="$2"
    local fix="$SCRATCH/run-${label}-$$"
    rm -rf "$fix"
    mkdir -p \
        "$fix/opt/mjolnir" \
        "$fix/opt/fixture/state" \
        "$fix/opt/fixture/stubs" \
        "$fix/varlib/btrfs/@vms/vm1" \
        "$fix/varlib/btrfs/@sites/tree" \
        "$fix/varlib/escrow" \
        "$fix/varlib/deploy/secrets" \
        "$fix/etc/systemd/system" \
        "$fix/etc/mjolnir" \
        "$fix/etc/modules-load.d" \
        "$fix/usr-local" \
        "$fix/compile/lib/mjolnir" \
        "$fix/compile/priv"

    write_stubs "$fix"
    seed_tree "$fix"
    compile_old_release "$fix"

    set +e
    bwrap \
        --unshare-user --uid 0 --gid 0 --die-with-parent \
        --ro-bind / / \
        --dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        --bind "$HOME" "$HOME" \
        --bind "$fix/opt" /opt \
        --bind "$fix/varlib" /var/lib/mjolnir \
        --bind "$fix/etc/systemd" /etc/systemd \
        --bind "$fix/etc/mjolnir" /etc/mjolnir \
        --bind "$fix/etc/modules-load.d" /etc/modules-load.d \
        --bind "$fix/usr-local" /usr/local \
        --setenv PATH "/opt/fixture/stubs:${ERL_BIN}:${ELIXIR_BIN}:/usr/bin:/bin" \
        --setenv HOME "$HOME" \
        --setenv SYSTEMCTL_LOG /opt/fixture/systemctl.log \
        --setenv SYSTEMCTL_STATE /opt/fixture/state \
        --setenv MJOLNIR_RSYNC_DEST /opt/mjolnir/ \
        --setenv MJOLNIR_CARGO /opt/fixture/stubs/cargo \
        --setenv MJOLNIR_MIX /opt/fixture/stubs/mix \
        --setenv MJOLNIR_FIXTURE_CARGO "$(case_cargo "$label")" \
        --setenv MJOLNIR_FIXTURE_MIX "$(case_mix "$label")" \
        --setenv MJOLNIR_FIXTURE_ID "$(cat "$fix/fixture-id")" \
        --setenv MIX_LOG /opt/fixture/mix.log \
        --setenv CARGO_LOG /opt/fixture/cargo.log \
        --setenv ELIXIR "$ELIXIR" \
        --setenv ELIXIRC "$ELIXIRC" \
        --setenv OLD_ID "$(cat "$fix/old-id")" \
        --setenv CASE_LABEL "$label" \
        -- \
        bash "$ROOT/scripts/deploy_test.sh" --inside "$label" \
        > "$fix/transcript" 2>&1
    local status=$?
    set -e
    cat "$fix/transcript" | tee -a "$logfile"
    if [[ "$status" -ne 0 ]]; then
        echo "FAIL $label (exit $status). Fixture left at $fix" | tee -a "$logfile" >&2
        exit "$status"
    fi
    rm -rf "$fix"
}

case_cargo() {
    case "$1" in
        fail) echo fail ;;
        *) echo ok ;;
    esac
}

case_mix() {
    case "$1" in
        release-fail) echo fail ;;
        gateway) echo skip ;;
        *) echo ok ;;
    esac
}

write_stubs() {
    local fix="$1"
    local d="$fix/opt/fixture/stubs"

    cat > "$d/ssh" << 'EOF'
#!/bin/bash
host=""
cmd=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -*) shift ;;
    *)
      if [[ -z "$host" ]]; then host="$1"; else cmd+="$1 "; fi
      shift
      ;;
  esac
done
exec bash -c "$cmd"
EOF

    cat > "$d/systemctl" << 'EOF'
#!/bin/bash
set -u
LOG="${SYSTEMCTL_LOG:?}"
STATE="${SYSTEMCTL_STATE:?}"
{
  printf 'systemctl'
  for a in "$@"; do printf ' %s' "$a"; done
  printf '\n'
} >> "$LOG"

cmd=""
unit=""
quiet=0
for a in "$@"; do
  case "$a" in
    daemon-reload|enable|disable|mask|start|stop|restart|status|is-active|is-enabled) cmd="$a" ;;
    --quiet|--no-pager|--now) [[ "$a" == "--quiet" ]] && quiet=1 ;;
    --*) ;;
    *) unit="$a" ;;
  esac
done
unit="${unit%.service}"

door_sha() {
  local f=/opt/mjolnir/bin/mjolnir-blob-door
  if [[ -s "$f" ]]; then
    echo "door-at-stop $(wc -c < "$f" | tr -d ' ') $(sha256sum "$f" | awk '{print $1}')" >> "$LOG"
  else
    echo "door-at-stop MISSING" >> "$LOG"
  fi
}

# Erlang ports setsid, so they are not in the beam's process group. A unit
# restart still kills them (systemd KillMode=control-group). Walk children
# before the beam is gone and the port gets reparented.
kill_tree() {
  local pid="$1" child
  for child in $(ps -o pid= --ppid "$pid" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -KILL "$pid" 2>/dev/null || true
}

kill_node() {
  local pidfile="$STATE/node.pid"
  [[ -f "$pidfile" ]] || return 0
  local pid
  pid="$(cat "$pidfile")"
  [[ -n "$pid" ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill_tree "$pid"
  fi
  echo inactive > "$STATE/mjolnir"
}

# systemd 262: an explicit stop or restart of a unit also stops or restarts
# units that Requires= it. The fixture reads installed unit files so a
# hotel-ip restart is visible as a redis and blob-door restart.
apply_unit() {
  local verb="$1" name="$2"
  name="${name%.service}"
  if [[ "$name" == "mjolnir" ]]; then
    kill_node
  elif [[ "$name" == "mjolnir-blob-door" ]]; then
    door_sha
    if [[ -f "$STATE/door.pid" ]]; then
      kill "$(cat "$STATE/door.pid")" 2>/dev/null || true
    fi
    if [[ "$verb" == "restart" ]]; then
      echo active > "$STATE/$name"
    else
      echo inactive > "$STATE/$name"
    fi
  else
    if [[ "$verb" == "stop" ]]; then
      echo inactive > "$STATE/$name"
    else
      echo active > "$STATE/$name"
    fi
  fi
  propagate_requires "$verb" "$name"
}

propagate_requires() {
  local verb="$1" name="$2"
  local f dep
  shopt -s nullglob
  for f in /etc/systemd/system/*.service /usr/lib/systemd/system/*.service /lib/systemd/system/*.service; do
    [[ -f "$f" ]] || continue
    dep="$(basename "$f" .service)"
    [[ "$dep" == "$name" ]] && continue
    if grep -Eq "^Requires=(.*[[:space:]])?${name}(\.service)?([[:space:]]|$)" "$f"; then
      local mark="$STATE/propagated-${verb}-${name}-${dep}"
      [[ -e "$mark" ]] && continue
      : > "$mark"
      echo "systemctl $verb $dep" >> "$LOG"
      apply_unit "$verb" "$dep"
    fi
  done
}

case "$cmd" in
  is-active)
    st="$(cat "$STATE/$unit" 2>/dev/null || echo inactive)"
    [[ "$quiet" -eq 1 ]] || echo "$st"
    [[ "$st" == active ]]
    ;;
  is-enabled)
    case "$unit" in
      mjolnir-gateway|forgejo-runner) echo enabled; exit 0 ;;
      *) echo disabled; exit 1 ;;
    esac
    ;;
  restart|stop)
    rm -f "$STATE"/propagated-"$cmd"-*
    apply_unit "$cmd" "$unit"
    ;;
  start)
    echo active > "$STATE/${unit:-unknown}"
    ;;
  status)
    echo "Active: $(cat "$STATE/$unit" 2>/dev/null || echo inactive)"
    ;;
  *)
    exit 0
    ;;
esac
EOF

    cat > "$d/cargo" << 'EOF'
#!/bin/bash
echo "cargo $*" >> "${CARGO_LOG:?}"
if [[ "${MJOLNIR_FIXTURE_CARGO:-ok}" == "fail" ]]; then
  echo "fixture cargo: build failed" >&2
  exit 1
fi
rel="/opt/mjolnir/native/target/release"
mkdir -p "$rel"
printf 'new-door-%s\n' "${MJOLNIR_FIXTURE_ID:?}" > "$rel/mjolnir-blob-door"
printf 'new-b3-%s\n' "${MJOLNIR_FIXTURE_ID:?}" > "$rel/mjolnir-b3"
chmod 0755 "$rel/mjolnir-blob-door" "$rel/mjolnir-b3"
if [[ "$*" == *mjolnir_gateway* || "$PWD" == *mjolnir_gateway* ]]; then
  printf 'new-gateway-%s\n' "$MJOLNIR_FIXTURE_ID" > "$rel/mjolnir-gateway"
  chmod 0755 "$rel/mjolnir-gateway"
fi
EOF

    cat > "$d/mix" << 'EOF'
#!/bin/bash
echo "mix $*" >> "${MIX_LOG:?}"
if [[ "${MJOLNIR_FIXTURE_MIX:-ok}" == "skip" ]]; then
  echo "fixture mix should not have been called: $*" >&2
  exit 1
fi
if [[ "$*" == *release* ]]; then
  if [[ "${MJOLNIR_FIXTURE_MIX}" == "fail" ]]; then
    echo "fixture mix release failed" >&2
    exit 1
  fi
  ebin="/opt/mjolnir/_build/prod/rel/mjolnir/lib/mjolnir-0.1.0/ebin"
  mkdir -p "$ebin"
  "${ELIXIRC:?}" -o "$ebin" \
    /opt/mjolnir/lib/mjolnir/release.ex \
    /opt/mjolnir/lib/mjolnir/code.ex \
    /opt/mjolnir/lib/mjolnir/cutover.ex
fi
exit 0
EOF

    cat > "$d/apt-get" << 'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$d/curl" << 'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$d/ss" << 'EOF'
#!/bin/bash
echo "LISTEN 0 128 10.200.0.1:6379"
echo "LISTEN 0 128 10.200.0.1:7222"
EOF
    cat > "$d/ufw" << 'EOF'
#!/bin/bash
[[ "${1:-}" == "status" ]] && echo "Status: inactive"
exit 0
EOF
    cat > "$d/iptables" << 'EOF'
#!/bin/bash
if [[ "$*" == *-S* ]]; then
  echo "-A POSTROUTING -s 10.200.0.0/10 -j MASQUERADE"
fi
exit 0
EOF
    cat > "$d/ip" << 'EOF'
#!/bin/bash
if [[ "$*" == *route* ]]; then
  echo "default via 203.0.113.1 dev eth0"
elif [[ "$*" == *"addr show dummy-mjolnir"* ]]; then
  echo "    inet 10.200.0.1/32 scope global dummy-mjolnir"
elif [[ "$*" == *"link show dummy-mjolnir"* ]]; then
  echo "2: dummy-mjolnir: <BROADCAST,NOARP,UP,LOWER_UP> mtu 1500"
fi
exit 0
EOF
    cat > "$d/chown" << 'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$d/modprobe" << 'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$d/install" << 'EOF'
#!/bin/bash
args=()
skip=0
for a in "$@"; do
  if [[ "$skip" -eq 1 ]]; then skip=0; continue; fi
  case "$a" in
    -o|-g|--owner|--group) skip=1 ;;
    -o*|--owner=*|-g*|--group=*) ;;
    *) args+=("$a") ;;
  esac
done
exec /usr/bin/install "${args[@]}"
EOF

    chmod 0755 "$d"/*
}

seed_tree() {
    local fix="$1"
    local id="fix-$(openssl rand -hex 8)"
    local old="old-$(openssl rand -hex 8)"
    printf '%s\n' "$id" > "$fix/fixture-id"
    printf '%s\n' "$old" > "$fix/old-id"

    mkdir -p "$fix/opt/mjolnir/bin" "$fix/opt/mjolnir/lib" \
        "$fix/opt/mjolnir/native/mjolnir_guest_agent/target/release" \
        "$fix/opt/mjolnir/_build/prod"
    printf 'old-door-%s\n' "$old" > "$fix/opt/mjolnir/bin/mjolnir-blob-door"
    printf 'old-b3-%s\n' "$old" > "$fix/opt/mjolnir/bin/mjolnir-b3"
    printf 'other-host-%s\n' "$old" > "$fix/opt/mjolnir/bin/other-host-tool"
    printf 'host-only-%s\n' "$old" > "$fix/opt/mjolnir/host-only-marker"
    printf 'removed-from-source\n' > "$fix/opt/mjolnir/lib/removed-from-source.ex"
    printf 'build-keep-%s\n' "$old" > "$fix/opt/mjolnir/_build/prod/keep"
    printf 'target-keep-%s\n' "$old" > "$fix/opt/mjolnir/native/mjolnir_guest_agent/target/release/keep"

    printf 'biscuit-root-sentinel\n' > "$fix/varlib/biscuit-root"
    printf 'escrow-sentinel\n' > "$fix/varlib/escrow/vm1"
    printf 'disk-sentinel\n' > "$fix/varlib/btrfs/@vms/vm1/disk"
    printf 'sites-sentinel\n' > "$fix/varlib/btrfs/@sites/tree/file"
    printf 'secret-sentinel\n' > "$fix/varlib/deploy/secrets/app.json"
    printf 'BLOB_DOOR_BIND=10.200.0.1:7222\n' > "$fix/etc/mjolnir/blob-door.env"
    chmod 0600 "$fix/etc/mjolnir/blob-door.env"

    for unit in mjolnir mjolnir-redis mjolnir-blob-door mjolnir-hotel-ip; do
        echo active > "$fix/opt/fixture/state/$unit"
    done
    cp -a "$ROOT/systemd/mjolnir-blob-door.service" \
        "$ROOT/systemd/mjolnir-redis.service" \
        "$fix/etc/systemd/system/"

    mkdir -p "$fix/opt/mjolnir/systemd" "$fix/opt/mjolnir/scripts/systemd"
    cp -a "$ROOT/systemd/mjolnir-redis.service" "$ROOT/systemd/mjolnir-redis.conf" \
        "$ROOT/systemd/mjolnir-hotel-ip.service" "$fix/opt/mjolnir/systemd/"
    cp -a "$ROOT/scripts/ensure-host-api-addr.sh" "$ROOT/scripts/backup-redis-b2.sh" \
        "$ROOT/scripts/install-redis.sh" "$fix/opt/mjolnir/scripts/"
    cp -a "$ROOT/scripts/systemd/mjolnir-redis-backup.service" \
        "$ROOT/scripts/systemd/mjolnir-redis-backup.timer" \
        "$fix/opt/mjolnir/scripts/systemd/"

    cat > "$fix/opt/fixture/guest.sh" << 'EOF'
#!/bin/bash
echo $$ > "$1"
exec sleep 3600
EOF
    chmod 0755 "$fix/opt/fixture/guest.sh"

    cat > "$fix/opt/fixture/node.exs" << 'EOF'
guest = System.fetch_env!("GUEST_SCRIPT")
guest_pid = System.fetch_env!("GUEST_PIDFILE")
port_file = System.fetch_env!("FIXTURE_PORT_FILE")
node_pid = System.fetch_env!("NODE_PIDFILE")
File.write!(node_pid, to_string(System.pid()))
Port.open({:spawn_executable, guest}, [:nouse_stdio, :exit_status, args: [guest_pid]])

defmodule FixtureServer do
  def listen(port_file) do
    {:ok, ls} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(ls)
    File.write!(port_file, Integer.to_string(port))
    accept(ls)
  end

  defp accept(ls) do
    {:ok, sock} = :gen_tcp.accept(ls)
    handle(sock)
    :gen_tcp.close(sock)
    accept(ls)
  end

  defp handle(sock) do
    {:ok, raw} = read_all(sock, "")
    {status, resp} =
      try do
        cond do
          String.starts_with?(raw, "GET /health") ->
            {200, Mjolnir.Release.id()}

          String.starts_with?(raw, "GET /code") ->
            {200, Mjolnir.Code.revision()}

          String.starts_with?(raw, "POST /rpc") ->
            body = request_body(sock, raw)
            {val, _} = Code.eval_string(body)
            {200, to_string(val)}

          true ->
            {404, "no"}
        end
      rescue
        e -> {500, Exception.message(e)}
      end

    msg =
      "HTTP/1.1 #{status} OK\r\ncontent-length: #{byte_size(resp)}\r\nconnection: close\r\n\r\n#{resp}"

    :gen_tcp.send(sock, msg)
  end

  defp read_all(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(sock, 0, 5_000) do
        {:ok, data} -> read_all(sock, acc <> data)
        other -> other
      end
    end
  end

  defp request_body(sock, raw) do
    [head, rest] = String.split(raw, "\r\n\r\n", parts: 2)

    len =
      case Regex.run(~r/content-length:\s*(\d+)/i, head) do
        [_, n] -> String.to_integer(n)
        _ -> 0
      end

    have = byte_size(rest)
    cond do
      len <= have -> binary_part(rest, 0, len)
      true ->
        {:ok, more} = :gen_tcp.recv(sock, len - have, 5_000)
        rest <> more
    end
  end
end

FixtureServer.listen(port_file)
EOF

    local ebin="$fix/opt/mjolnir/_build/prod/rel/mjolnir/lib/mjolnir-0.1.0/ebin"
    mkdir -p "$ebin" "$fix/opt/mjolnir/_build/prod/rel/mjolnir/bin"
    cat > "$fix/opt/mjolnir/_build/prod/rel/mjolnir/bin/mjolnir" << 'EOF'
#!/bin/bash
set -euo pipefail
[[ "${1:-}" == "rpc" ]] || { echo "fixture release bin: only rpc" >&2; exit 1; }
port="$(cat /opt/fixture/port)"
exec /usr/bin/curl -fsS --data-binary "$2" "http://127.0.0.1:${port}/rpc"
EOF
    chmod 0755 "$fix/opt/mjolnir/_build/prod/rel/mjolnir/bin/mjolnir"
}

compile_old_release() {
    local fix="$1"
    cp "$ROOT/lib/mjolnir/release.ex" "$ROOT/lib/mjolnir/code.ex" \
        "$ROOT/lib/mjolnir/cutover.ex" "$fix/compile/lib/mjolnir/"
    printf '%s\n' "$(cat "$fix/old-id")" > "$fix/compile/priv/release_id"
    local ebin="$fix/opt/mjolnir/_build/prod/rel/mjolnir/lib/mjolnir-0.1.0/ebin"
    "$ELIXIRC" -o "$ebin" \
        "$fix/compile/lib/mjolnir/release.ex" \
        "$fix/compile/lib/mjolnir/code.ex" \
        "$fix/compile/lib/mjolnir/cutover.ex"
}

inside_main() {
    local label="$1"
    set -euo pipefail
    trap 'fixture_cleanup' EXIT
    echo "inside $label cargo=${MJOLNIR_FIXTURE_CARGO} mix=${MJOLNIR_FIXTURE_MIX}"

    : > /opt/fixture/systemctl.log
    : > /opt/fixture/mix.log
    : > /opt/fixture/cargo.log

    # Previous redis install so an unchanged unit/config/binary is not restarted.
    bash /opt/mjolnir/scripts/install-redis.sh
    : > /opt/fixture/systemctl.log

    echo active > /opt/fixture/state/mjolnir
    echo active > /opt/fixture/state/mjolnir-redis
    echo active > /opt/fixture/state/mjolnir-blob-door
    echo active > /opt/fixture/state/mjolnir-hotel-ip
    sleep 3600 &
    echo $! > /opt/fixture/state/door.pid

    start_node
    old_health="$(/usr/bin/curl -fsS "http://127.0.0.1:$(cat /opt/fixture/port)/health")"
    [[ "$old_health" == "$OLD_ID" ]] || { echo "health $old_health != $OLD_ID" >&2; exit 1; }
    guest_pid="$(cat /opt/fixture/guest.pid)"
    kill -0 "$guest_pid"

    if [[ "$label" == "cutover" ]]; then
        echo "--- proof: systemctl restart mjolnir kills the guest ---"
        systemctl restart mjolnir
        if kill -0 "$guest_pid" 2>/dev/null; then
            echo "proof failed: guest $guest_pid still alive after restart" >&2
            exit 1
        fi
        echo "proof: guest $guest_pid killed"
        start_node
        guest_pid="$(cat /opt/fixture/guest.pid)"
        old_health="$(/usr/bin/curl -fsS "http://127.0.0.1:$(cat /opt/fixture/port)/health")"
        [[ "$old_health" == "$OLD_ID" ]]
        : > /opt/fixture/systemctl.log
        echo active > /opt/fixture/state/mjolnir
        echo active > /opt/fixture/state/mjolnir-blob-door
        echo active > /opt/fixture/state/mjolnir-hotel-ip
        echo active > /opt/fixture/state/mjolnir-redis
        # door sleeper was not part of the node group; restart mjolnir did not kill it
        if ! kill -0 "$(cat /opt/fixture/state/door.pid)" 2>/dev/null; then
            sleep 3600 &
            echo $! > /opt/fixture/state/door.pid
        fi
    fi

    snapshot_hashes /opt/fixture/before.sha
    door_before="$(sha256sum /opt/mjolnir/bin/mjolnir-blob-door | awk '{print $1}')"
    b3_before="$(sha256sum /opt/mjolnir/bin/mjolnir-b3 | awk '{print $1}')"

    set +e
    if [[ "$label" == "gateway" ]]; then
        bash "$ROOT/scripts/deploy.sh" root@fixture --gateway
    else
        bash "$ROOT/scripts/deploy.sh" root@fixture
    fi
    deploy_status=$?
    set -e
    echo "deploy_exit=$deploy_status"

    slog=/opt/fixture/systemctl.log
    if grep -E '^systemctl (restart|stop) mjolnir$' "$slog"; then
        echo "mjolnir unit was stopped or restarted" >&2
        exit 1
    fi
    if grep -E '^systemctl restart mjolnir-redis$' "$slog"; then
        echo "unchanged redis was restarted" >&2
        exit 1
    fi
    if grep -E '^systemctl restart forgejo-runner$' "$slog"; then
        echo "forgejo-runner was restarted" >&2
        exit 1
    fi
    if grep -E '^systemctl (restart|stop) mjolnir-hotel-ip(\.service)?$' "$slog"; then
        echo "hotel-ip was restarted while the address was already up" >&2
        exit 1
    fi

    snapshot_hashes /opt/fixture/after.sha
    if ! cmp -s /opt/fixture/before.sha /opt/fixture/after.sha; then
        echo "guest or secret bytes changed" >&2
        diff -u /opt/fixture/before.sha /opt/fixture/after.sha >&2 || true
        exit 1
    fi

    [[ -f /opt/mjolnir/bin/other-host-tool ]]
    [[ -f /opt/mjolnir/host-only-marker ]]
    [[ -f /opt/mjolnir/_build/prod/keep ]]
    [[ -f /opt/mjolnir/native/mjolnir_guest_agent/target/release/keep ]]
    [[ ! -e /opt/mjolnir/lib/removed-from-source.ex ]]
    grep -q 'ExecStart=/opt/mjolnir/bin/mjolnir-blob-door' /etc/systemd/system/mjolnir-blob-door.service 2>/dev/null || {
        # fail case never installs the unit; the file may be absent
        [[ "$label" == "fail" ]] || { echo "missing door unit ExecStart" >&2; exit 1; }
    }

    kill -0 "$guest_pid" || { echo "guest $guest_pid died" >&2; exit 1; }

    case "$label" in
        fail)
            [[ "$deploy_status" -ne 0 ]]
            [[ "$(sha256sum /opt/mjolnir/bin/mjolnir-blob-door | awk '{print $1}')" == "$door_before" ]]
            [[ "$(sha256sum /opt/mjolnir/bin/mjolnir-b3 | awk '{print $1}')" == "$b3_before" ]]
            if grep -E '^systemctl (restart|stop) mjolnir-blob-door$' "$slog"; then
                echo "blob door was stopped after a failed build" >&2
                exit 1
            fi
            kill -0 "$(cat /opt/fixture/state/door.pid)"
            if grep -E '^systemctl restart mjolnir-gateway$' "$slog"; then
                echo "gateway restarted" >&2
                exit 1
            fi
            ;;
        release-fail)
            [[ "$deploy_status" -ne 0 ]]
            health="$(/usr/bin/curl -fsS "http://127.0.0.1:$(cat /opt/fixture/port)/health")"
            [[ "$health" == "$OLD_ID" ]]
            code="$(/usr/bin/curl -fsS "http://127.0.0.1:$(cat /opt/fixture/port)/code")"
            [[ "$code" == "$OLD_ID" ]]
            grep -q 'mix release' /opt/fixture/mix.log
            if grep -E '^systemctl restart mjolnir-gateway$' "$slog"; then
                echo "gateway restarted" >&2
                exit 1
            fi
            ;;
        gateway)
            [[ "$deploy_status" -eq 0 ]]
            [[ ! -s /opt/fixture/mix.log ]]
            grep -E '^systemctl restart mjolnir-gateway$' "$slog" >/dev/null
            health="$(/usr/bin/curl -fsS "http://127.0.0.1:$(cat /opt/fixture/port)/health")"
            [[ "$health" == "$OLD_ID" ]]
            code="$(/usr/bin/curl -fsS "http://127.0.0.1:$(cat /opt/fixture/port)/code")"
            [[ "$code" == "$OLD_ID" ]]
            ;;
        cutover)
            [[ "$deploy_status" -eq 0 ]]
            if grep -E '^systemctl restart mjolnir-gateway$' "$slog"; then
                echo "gateway restarted without a gateway build" >&2
                exit 1
            fi
            new_id="$(tr -d '[:space:]' < /opt/mjolnir/priv/release_id)"
            health="$(/usr/bin/curl -fsS "http://127.0.0.1:$(cat /opt/fixture/port)/health")"
            [[ "$health" == "$new_id" ]]
            [[ "$health" != "$OLD_ID" ]]
            [[ -n "$health" ]]
            code="$(/usr/bin/curl -fsS "http://127.0.0.1:$(cat /opt/fixture/port)/code")"
            [[ "$code" == "$new_id" ]]
            [[ "$code" != "$OLD_ID" ]]
            [[ "$code" == "$health" ]]
            door_now="$(sha256sum /opt/mjolnir/bin/mjolnir-blob-door | awk '{print $1}')"
            b3_now="$(sha256sum /opt/mjolnir/bin/mjolnir-b3 | awk '{print $1}')"
            [[ "$door_now" != "$door_before" ]]
            [[ "$b3_now" != "$b3_before" ]]
            built="$(sha256sum /opt/mjolnir/native/target/release/mjolnir-blob-door | awk '{print $1}')"
            [[ "$door_now" == "$built" ]]
            first_stop="$(grep -m1 '^door-at-stop ' "$slog")"
            [[ "$first_stop" == "door-at-stop "* ]]
            [[ "$first_stop" != *MISSING* ]]
            [[ "$first_stop" == *"$door_now"* ]]
            grep -E '^systemctl (restart|stop) mjolnir-blob-door$' "$slog" >/dev/null
            # disk sentinel still the guest's disk
            [[ "$(cat /var/lib/mjolnir/btrfs/@vms/vm1/disk)" == "disk-sentinel" ]]
            ;;
        *)
            echo "unknown label $label" >&2
            exit 1
            ;;
    esac
    echo "assertions ok ($label)"
}

fixture_cleanup() {
    local pid pgid
    if [[ -f /opt/fixture/state/node.pid ]]; then
        pid="$(cat /opt/fixture/state/node.pid 2>/dev/null || true)"
        if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
            pgid="$(ps -o pgid= -p "$pid" | tr -d ' ')"
            kill -KILL -- "-${pgid}" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    if [[ -f /opt/fixture/state/door.pid ]]; then
        kill "$(cat /opt/fixture/state/door.pid)" 2>/dev/null || true
    fi
}

start_node() {
    rm -f /opt/fixture/port /opt/fixture/guest.pid /opt/fixture/state/node.pid
    GUEST_SCRIPT=/opt/fixture/guest.sh \
        GUEST_PIDFILE=/opt/fixture/guest.pid \
        FIXTURE_PORT_FILE=/opt/fixture/port \
        NODE_PIDFILE=/opt/fixture/state/node.pid \
        setsid "$ELIXIR" -pa /opt/mjolnir/_build/prod/rel/mjolnir/lib/mjolnir-0.1.0/ebin \
            --no-halt /opt/fixture/node.exs >/opt/fixture/node.log 2>&1 &
    local i
    for i in $(seq 1 50); do
        [[ -s /opt/fixture/port && -s /opt/fixture/guest.pid ]] && return 0
        sleep 0.1
    done
    echo "node did not come up" >&2
    cat /opt/fixture/node.log >&2 || true
    exit 1
}

snapshot_hashes() {
    local out="$1"
    : > "$out"
    local f
    for f in \
        /var/lib/mjolnir/biscuit-root \
        /var/lib/mjolnir/escrow/vm1 \
        /var/lib/mjolnir/btrfs/@vms/vm1/disk \
        /var/lib/mjolnir/btrfs/@sites/tree/file \
        /var/lib/mjolnir/deploy/secrets/app.json
    do
        sha256sum "$f" >> "$out"
    done
}

main() {
    [[ -n "$ELIXIR" && -x "$ELIXIR" ]] || { echo "elixir not found" >&2; exit 1; }
    mkdir -p "$SCRATCH"
    case "${DEPLOY_TEST_ONLY:-all}" in
        fail)
            : > "$SCRATCH/deploy-fail.log"
            run_twice fail "$SCRATCH/deploy-fail.log"
            ;;
        release-fail)
            : > "$SCRATCH/deploy-release-fail.log"
            run_twice release-fail "$SCRATCH/deploy-release-fail.log"
            ;;
        gateway)
            : > "$SCRATCH/deploy-release-fail.log"
            run_twice gateway "$SCRATCH/deploy-release-fail.log"
            ;;
        cutover)
            : > "$SCRATCH/deploy-cutover.log"
            run_twice cutover "$SCRATCH/deploy-cutover.log"
            ;;
        all)
            : > "$SCRATCH/deploy-fail.log"
            : > "$SCRATCH/deploy-release-fail.log"
            : > "$SCRATCH/deploy-cutover.log"
            run_twice fail "$SCRATCH/deploy-fail.log"
            run_twice release-fail "$SCRATCH/deploy-release-fail.log"
            run_twice gateway "$SCRATCH/deploy-release-fail.log"
            run_twice cutover "$SCRATCH/deploy-cutover.log"
            ;;
        *) echo "unknown DEPLOY_TEST_ONLY" >&2; exit 1 ;;
    esac
    write_data_paths
    echo "deploy_test: ok"
}

write_data_paths() {
    local out="$SCRATCH/deploy-data-paths.txt"
    {
        echo "# Writes under /var/lib/mjolnir in the deploy procedure."
        echo "# A normal deploy (no --rootfs) must not change guest or secret bytes."
        echo "# Checked by the fixture sentinels: biscuit-root, escrow, @vms, @sites, deploy/secrets."
        echo "# No production host was contacted."
        echo
        grep -n '/var/lib/mjolnir' \
            "$ROOT/scripts/deploy.sh" \
            "$ROOT/scripts/install-blob-door.sh" \
            "$ROOT/scripts/install-redis.sh" \
            "$ROOT/scripts/cutover-release.sh" \
            "$ROOT/scripts/build-rootfs-arch.sh" \
            "$ROOT/scripts/build-rootfs-ubuntu-24.04.sh" \
            2>/dev/null || true
        echo
        echo "# deploy.sh uses /var/lib/mjolnir/btrfs only for --rootfs, and only as @base/<distro>."
        echo "# install-blob-door.sh creates BLOB_DOOR_CACHE_DIR (default /var/lib/mjolnir/blobs) and may delete legacy /var/lib/mjolnir/btrfs/@blobs. It does not write @vms, @sites, biscuit-root, escrow, or deploy secrets."
        echo "# install-redis.sh writes /var/lib/mjolnir/redis (AOF dir and install hash), not guest or secret files."
        echo "# build-rootfs-*.sh run only when deploy.sh is passed --rootfs."
    } > "$out"
}

if [[ "${1:-}" == "--inside" ]]; then
    inside_main "${2:?case}"
else
    main
fi
