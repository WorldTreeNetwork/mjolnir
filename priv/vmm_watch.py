import ctypes as c, ctypes.util, json, os, subprocess, sys, time
slice_name, record_path = sys.argv[1:]
sd = c.CDLL(ctypes.util.find_library('systemd') or 'libsystemd.so.0')
ptr = c.c_void_p
sd.sd_bus_open_system.argtypes = [c.POINTER(ptr)]
sd.sd_bus_call_method.argtypes = [ptr, c.c_char_p, c.c_char_p, c.c_char_p, c.c_char_p, ptr, c.POINTER(ptr), c.c_char_p]
sd.sd_bus_message_read_basic.argtypes = [ptr, c.c_char, ptr]
sd.sd_bus_message_enter_container.argtypes = [ptr, c.c_char, c.c_char_p]
sd.sd_bus_message_exit_container.argtypes = [ptr]
sd.sd_bus_message_skip.argtypes = [ptr, c.c_char_p]
sd.sd_bus_message_peek_type.argtypes = [ptr, c.POINTER(c.c_char), c.POINTER(c.c_char_p)]
for name in ('sd_bus_message_get_member', 'sd_bus_message_get_path'):
    getattr(sd, name).argtypes = [ptr]
    getattr(sd, name).restype = c.c_char_p
sd.sd_bus_process.argtypes = [ptr, ptr]
sd.sd_bus_wait.argtypes = [ptr, c.c_uint64]
def check(code):
    if code < 0: raise OSError(-code, os.strerror(-code))
    return code
bus = ptr()
check(sd.sd_bus_open_system(c.byref(bus)))
try:
    with open(record_path) as f: history = json.load(f)
    if not isinstance(history, dict): history = {}
except (OSError, ValueError): history = {}
members = {}
paths = {}
def persist(unit, state, result='unknown'):
    history[unit] = dict(state=state, result=result, slice=slice_name, observed_at=time.time())
    write_history()
def write_history():
    os.makedirs(os.path.dirname(record_path), exist_ok=True)
    temporary = record_path + '.tmp'
    with open(temporary, 'w') as f:
        json.dump(history, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temporary, record_path)
    directory = os.open(os.path.dirname(record_path), os.O_RDONLY)
    try: os.fsync(directory)
    finally: os.close(directory)
def inspect_unit(unit, path=None):
    if not unit.endswith('.scope'): return
    proc = subprocess.run(['systemctl', 'show', unit, '--property=Slice', '--property=ActiveState', '--property=Result'], capture_output=True, text=True)
    if proc.returncode: return
    props = dict(line.split('=', 1) for line in proc.stdout.splitlines() if '=' in line)
    if props.get('Slice') != slice_name: return
    members[unit] = props
    if path: paths[path] = unit
    persist(unit, props.get('ActiveState', 'unknown'), props.get('Result', 'unknown'))
def read(message, kind):
    value = c.c_char_p()
    if check(sd.sd_bus_message_read_basic(message, kind.encode(), c.byref(value))) == 0: return None
    return value.value.decode()
callback_type = c.CFUNCTYPE(c.c_int, ptr, ptr, ptr)
def on_message(message, userdata, error):
    try:
        member = sd.sd_bus_message_get_member(message).decode()
        path = sd.sd_bus_message_get_path(message).decode()
        if member in ('UnitNew', 'UnitRemoved'):
            unit, obj = read(message, 's'), read(message, 'o')
            if member == 'UnitNew': inspect_unit(unit, obj)
            elif unit in members:
                old = history.get(unit, {})
                if old.get('state') not in ('inactive', 'failed'):
                    persist(unit, 'inactive', old.get('result', 'unknown'))
                members.pop(unit, None)
                paths.pop(obj, None)
        elif member == 'PropertiesChanged':
            interface = read(message, 's')
            if interface not in ('org.freedesktop.systemd1.Unit', 'org.freedesktop.systemd1.Scope'): return 0
            # sd-bus encodes '-' as _2d etc in unit object paths.
            unit = paths.get(path)
            if unit is None:
                encoded = path.rsplit('/', 1)[-1]
                import re
                unit = re.sub(r'_([0-9a-f]{2})', lambda m: chr(int(m[1], 16)), encoded)
                inspect_unit(unit, path)
            if unit not in members: return 0
            props = members[unit]
            check(sd.sd_bus_message_enter_container(message, b'a', b'{sv}'))
            while sd.sd_bus_message_enter_container(message, b'e', b'sv') > 0:
                key = read(message, 's')
                typ, contents = c.c_char(), c.c_char_p()
                check(sd.sd_bus_message_peek_type(message, c.byref(typ), c.byref(contents)))
                if key in ('ActiveState', 'Result', 'Slice') and contents.value == b's':
                    check(sd.sd_bus_message_enter_container(message, b'v', b's'))
                    props[key] = read(message, 's')
                    check(sd.sd_bus_message_exit_container(message))
                else: check(sd.sd_bus_message_skip(message, b'v'))
                check(sd.sd_bus_message_exit_container(message))
            check(sd.sd_bus_message_exit_container(message))
            if props.get('Slice') == slice_name:
                persist(unit, props.get('ActiveState', 'unknown'), props.get('Result', 'unknown'))
    except BaseException:
        import traceback
        traceback.print_exc()
        # Fail visibly rather than continue with an incomplete witness.
        os._exit(1)
    return 0
callback = callback_type(on_message)
sd.sd_bus_add_match.argtypes = [ptr, c.POINTER(ptr), c.c_char_p, callback_type, ptr]
slot = ptr()
check(sd.sd_bus_add_match(bus, c.byref(slot), b"type='signal',sender='org.freedesktop.systemd1'", callback, None))
reply = ptr()
check(sd.sd_bus_call_method(bus, b'org.freedesktop.systemd1', b'/org/freedesktop/systemd1', b'org.freedesktop.systemd1.Manager', b'Subscribe', None, c.byref(reply), b''))
proc = subprocess.run(['systemctl', 'list-units', '--all', '--type=scope', '--plain', '--no-legend', '--no-pager'], capture_output=True, text=True, check=True)
for line in proc.stdout.splitlines():
    fields = line.split()
    if fields: inspect_unit(fields[0])
# Also write an empty readable record on a host with no guests.
write_history()
while True:
    while check(sd.sd_bus_process(bus, None)) > 0: pass
    check(sd.sd_bus_wait(bus, 1000000))
