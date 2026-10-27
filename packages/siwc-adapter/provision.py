"""Root-only runtime capability publication; never prints secret values."""
import os
from pathlib import Path
import pwd
import secrets
import stat
import sys
import tempfile


def directory(path, mode, group):
    path.mkdir(mode=mode, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise RuntimeError('unsafe runtime directory')
    os.chmod(path, mode)
    os.chown(path, os.getuid(), group)


def destination(path, owner):
    if path.exists() or path.is_symlink():
        st = path.lstat()
        if not stat.S_ISREG(st.st_mode) or st.st_uid != owner:
            raise RuntimeError('unsafe runtime destination')


def publish(path, data, ids):
    destination(path, ids[0])
    fd, name = tempfile.mkstemp(prefix='.pending-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as handle:
            os.fchmod(handle.fileno(), 0o600)
            os.fchown(handle.fileno(), *ids)
            handle.write(data)
            handle.flush(); os.fsync(handle.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


def provision(root, template, adapter_ids, agent_ids):
    directory(root, 0o711, os.getgid())
    directory(root / 'adapter', 0o750, adapter_ids[1])
    directory(root / 'agent', 0o750, agent_ids[1])
    master = root / 'capability'
    destination(master, os.getuid())
    destination(root / 'adapter/capability', adapter_ids[0])
    destination(root / 'agent/config.toml', agent_ids[0])
    if master.exists():
        with os.fdopen(os.open(master, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as handle:
            st = os.fstat(handle.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o600:
                raise RuntimeError('unsafe runtime master')
            value = handle.read(65).decode('ascii')
        if len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
            raise RuntimeError('invalid runtime master')
    else:
        value = secrets.token_hex(32)
        publish(master, value.encode(), (os.getuid(), os.getgid()))
    text = template.read_text()
    if text.count('@CAPABILITY@') != 1:
        raise RuntimeError('invalid runtime template')
    publish(root / 'adapter/capability', value.encode(), adapter_ids)
    publish(root / 'agent/config.toml', text.replace('@CAPABILITY@', value).encode(), agent_ids)


def main():
    if os.getuid() != 0:
        raise RuntimeError('runtime provisioning requires root')
    adapter, agent = pwd.getpwnam('zeroclaw'), pwd.getpwnam('zeroclaw-agent')
    provision(Path('/run/pi4-siwc'), Path(sys.argv[1]),
              (adapter.pw_uid, adapter.pw_gid), (agent.pw_uid, agent.pw_gid))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('SIWC runtime provisioning failed.', file=sys.stderr)
        sys.exit(1)
