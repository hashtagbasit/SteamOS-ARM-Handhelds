#!/usr/bin/env python3
"""Stage and recover offline Zaviya updates. Runs recovery from a private HOME root.
No partitioning or formatting commands are used. Games and Steam account data are excluded.
"""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time
import uuid
from pathlib import Path, PurePosixPath

FORMAT = 1
# DT models per SoC. Update packages are per SoC (the KERNEL is), and list
# exactly one of these (the v1.2 updater compares the SM8650 list verbatim).
SOC_MODELS = {
    'sm8650': ['KONKR Pocket FIT', 'AYANEO Pocket S2'],
    'sm8550': ['AYN Odin 2', 'AYN Odin 2 Mini', 'AYN Odin 2 Portal', 'AYN Thor',
               'AYANEO Pocket ACE', 'AYANEO Pocket DMG', 'AYANEO Pocket DS',
               'AYANEO Pocket EVO', 'AYANEO Pocket S 1K', 'AYANEO Pocket S 2K',
               'Retroid Pocket 6', 'Retroid Pocket 6 TOP-DPAD', 'Retroid Pocket Nova'],
    'sm8750': ['AYN Odin 3', 'KONKR Pocket FIT Elite'],
    'sm8250': ['Retroid Pocket 5', 'Retroid Pocket 5 Visionox', 'Retroid Pocket Flip2',
               'Retroid Pocket Flip2 Visionox', 'Retroid Pocket Mini', 'Retroid Pocket Mini V2',
               'AYN Thor Lite', 'MANGMI Air Y Pro', 'MANGMI Pocket Max',
               'AYANEO Pocket MICRO 2'],
}
SUPPORTED_MODELS = {m for models in SOC_MODELS.values() for m in models}
ROOT_DIRS = ('usr', 'opt', 'etc')
UPPER = 'var/lib/overlays/etc/upper'
HOME_DIRS = ('homebrew/plugins/konkr-control', 'homebrew/plugins/decky-lsfg-vk')
PRESERVE = ('passwd', 'shadow', 'group', 'gshadow', 'machine-id', 'hostname', 'hosts',
            'fstab', 'crypttab', 'localtime', 'adjtime', 'resolv.conf', 'ssh',
            'NetworkManager/system-connections', 'sudoers.d')
PENDING = 'var/lib/konkr-update/pending'


def run(*args, **kwargs):
    print('+', ' '.join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def digest(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(4 << 20), b''): h.update(b)
    return h.hexdigest()


def write_json(p, data):
    p = Path(p); p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(p.name + '.tmp')
    with tmp.open('w') as f:
        json.dump(data, f, indent=2); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, p)
    fd = os.open(p.parent, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)


def state(work, value):
    write_json(work / 'state.json', {'state': value, 'time': time.time()})
    print('STATE:', value, flush=True)


def copy_tree(src, dst, delete=False, excludes=()):
    dst.mkdir(parents=True, exist_ok=True)
    args = ['rsync', '-aHAX', '--checksum', '--numeric-ids']
    if delete: args.append('--delete')
    args += [f'--exclude=/{x}' for x in excludes]
    run(*args, str(src) + '/', str(dst) + '/')


def mount_info(path):
    r = run('findmnt', '-J', '-o', 'SOURCE,FSTYPE,TARGET,UUID', '-T', path,
            capture_output=True, text=True)
    return json.loads(r.stdout)['filesystems'][0]


def validate_archive(package):
    seen = set(); links = set(); directories = set(); total = 0; manifest = None
    with tarfile.open(package, 'r:gz') as tf:
        for m in tf:
            name = m.name.removeprefix('./').rstrip('/')
            p = PurePosixPath(name)
            if not name or p.is_absolute() or '..' in p.parts or name in seen:
                raise ValueError(f'unsafe or duplicate archive path: {name}')
            if any(str(a) in links for a in p.parents):
                raise ValueError(f'archive writes through symlink: {name}')
            seen.add(name)
            if not (m.isfile() or m.isdir() or m.issym() or m.islnk()):
                raise ValueError(f'special file in package: {name}')
            if m.isdir(): directories.add(name)
            if m.issym(): links.add(name)
            elif m.islnk():
                q = PurePosixPath(m.linkname.removeprefix('./'))
                if q.is_absolute() or '..' in q.parts or str(q) not in seen:
                    raise ValueError(f'unsafe hard link: {name}')
            if m.isfile(): total += m.size
            if name == 'manifest.json':
                if not m.isfile() or m.size > 32 << 20: raise ValueError('invalid manifest')
                manifest = json.load(tf.extractfile(m))
            elif not (name == 'root' or name.startswith(('root/usr/', 'root/opt/', 'root/etc/',
                     'root/var/lib/overlays/etc/upper/', 'home/steamos/', 'boot/')) or
                     name in ('root/usr', 'root/opt', 'root/etc', 'root/var', 'root/var/lib',
                     'root/var/lib/overlays', 'root/var/lib/overlays/etc',
                     'root/var/lib/overlays/etc/upper', 'home', 'home/steamos', 'boot')):
                raise ValueError(f'unsupported payload path: {name}')
    if not {'root/usr', 'root/opt', 'root/etc', 'boot'}.issubset(directories):
        raise ValueError('required payload directories must be real directories')
    if not manifest or manifest.get('format') != FORMAT or manifest.get('architecture') != 'aarch64':
        raise ValueError('unsupported update format or architecture')
    devices = manifest.get('devices')
    if not isinstance(devices, list) or not devices or not set(devices) <= SUPPORTED_MODELS:
        raise ValueError('unsupported device list')
    files = manifest.get('files', {})
    if not isinstance(files, dict): raise ValueError('invalid file manifest')
    # Every regular file must be covered, and file keys cannot escape extraction.
    with tarfile.open(package, 'r:gz') as tf:
        actual = {m.name.removeprefix('./'): m for m in tf if (m.isfile() or m.islnk()) and m.name.removeprefix('./') != 'manifest.json'}
    if set(actual) != set(files): raise ValueError('manifest does not cover all payload files')
    for name, sha in files.items():
        if not re.fullmatch('[0-9a-f]{64}', sha): raise ValueError(f'invalid checksum: {name}')
    return manifest, total


def verify_payload(payload, manifest):
    for name, sha in manifest['files'].items():
        p = payload / name
        if p.is_symlink() or not p.is_file() or digest(p) != sha:
            raise ValueError(f'payload checksum mismatch: {name}')
    for d in ROOT_DIRS:
        if (payload / 'root' / d).is_symlink() or not (payload / 'root' / d).is_dir(): raise ValueError(f'missing system directory: {d}')
    if not (payload / 'boot/KERNEL').is_file(): raise ValueError('missing KERNEL')


# ---------------------------------------------------------------- format 2 ---
# A format 2 package is signed and content-addressed:
#   manifest.json  every managed path of the release it installs:
#                    "f": [mode, uid, gid, size, sha256, {xattr: hex}]
#                    "l": [target]           "d": [mode, uid, gid]
#                  plus "blobs": the sha256s whose contents ship in blobs/.
#   manifest.sig   Ed25519 signature of manifest.json (openssl pkeyutl -rawin)
#   blobs/aa/<sha256>
# A full package ships every blob, a delta only those none of its "from"
# releases had. The device works out what to change by comparing the
# manifest with its own files, so only changed files are backed up and
# written; the install inventory recorded at build time spares hashing a
# file whose size and mtime it still matches.
FORMAT2 = 2
MANAGED = ('root/usr', 'root/opt', 'root/etc', 'root/' + UPPER,
           *('home/steamos/' + rel for rel in HOME_DIRS))
INVENTORY = 'usr/share/steamos-arm/update/installed.json'
SIGNING_KEY = Path('/usr/share/steamos-arm/update/signing.pub')


def entry_for(path):
    st = os.lstat(path)
    import stat as S
    if S.S_ISLNK(st.st_mode): return {'l': [os.readlink(path)]}
    if S.S_ISDIR(st.st_mode): return {'d': [S.S_IMODE(st.st_mode), st.st_uid, st.st_gid]}
    # overlayfs whiteouts in the /etc upper layer: a deleted file
    if S.S_ISCHR(st.st_mode) and st.st_rdev == 0: return {'w': []}
    if not S.S_ISREG(st.st_mode): raise ValueError(f'special file in managed tree: {path}')
    return {'f': [S.S_IMODE(st.st_mode), st.st_uid, st.st_gid, st.st_size, digest(path), xattrs_of(path)]}


def xattrs_of(path):
    xattrs = {}
    try:
        for name in os.listxattr(path, follow_symlinks=False):
            if name.startswith(('security.capability', 'user.')):
                xattrs[name] = os.getxattr(path, name, follow_symlinks=False).hex()
    except OSError:
        pass
    return xattrs


def is_transient(key):
    """Python bytecode caches and pacman sync databases drift at runtime and are not managed."""
    return '/__pycache__/' in key or key.endswith('/__pycache__') or '/pacmandb/sync/' in key or key.endswith('/pacmandb/sync')


def walk_managed(base_of, skip_etc=False):
    """{managed path: entry}. base_of maps a managed prefix to a real directory."""
    out = {}
    for prefix in MANAGED:
        base = base_of(prefix)
        if base is None or not base.exists(): continue
        for dirpath, dirs, files in os.walk(base):
            dirs.sort()
            rel = os.path.relpath(dirpath, base)
            key = prefix if rel == '.' else f'{prefix}/{rel}'
            if skip_etc and preserved(key): dirs[:] = []; continue
            out[key] = entry_for(dirpath)
            for name in sorted(files) + [d for d in dirs if os.path.islink(os.path.join(dirpath, d))]:
                k = f'{key}/{name}'
                if skip_etc and preserved(k): continue
                out[k] = entry_for(os.path.join(dirpath, name))
            dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(dirpath, d))]
    return out


def preserved(key):
    """Identity, accounts and credentials under etc are never managed."""
    for prefix in ('root/etc/', 'root/' + UPPER + '/'):
        if key.startswith(prefix):
            rel = key[len(prefix):]
            return any(rel == p or rel.startswith(p + '/') for p in PRESERVE)
    return False


def sign_manifest(manifest_path, key_path, sig_path):
    run('openssl', 'pkeyutl', '-sign', '-inkey', key_path, '-rawin', '-in', manifest_path, '-out', sig_path)


def verify_signature(manifest_path, sig_path, pub=SIGNING_KEY):
    if not pub.is_file(): raise ValueError('no update signing key on this system')
    r = subprocess.run(['openssl', 'pkeyutl', '-verify', '-pubin', '-inkey', str(pub), '-rawin',
                        '-in', str(manifest_path), '-sigfile', str(sig_path)], capture_output=True, text=True)
    if r.returncode != 0 or 'Signature Verified Successfully' not in r.stdout:
        raise ValueError('update signature does not verify: not an official release')


BOOTIMG = Path('/usr/share/easy-ufs-install/ufs-bootimg.py')


def bootimg_helper(payload=None):
    """v1.1 has no ufs-bootimg.py; the update payload carries the new one."""
    if BOOTIMG.is_file(): return BOOTIMG
    if payload is not None:
        bundled = payload / 'root' / str(BOOTIMG).lstrip('/')
        if bundled.is_file(): return bundled
    raise ValueError('boot image helper not found (ufs-bootimg.py)')


def recovery_runtime(dst, helper=BOOTIMG):
    """Copy executables, Python stdlib, and all their resolved shared libraries."""
    dst.mkdir(parents=True, exist_ok=True)
    sources = [Path(shutil.which('python3')).resolve(), Path(shutil.which('rsync')).resolve(), Path(shutil.which('chown')).resolve(), Path(shutil.which('findmnt')).resolve()]
    lib = Path(sys.base_prefix) / 'lib' / f'python{sys.version_info.major}.{sys.version_info.minor}'
    copy_tree(lib, dst / str(lib).lstrip('/'), excludes=('site-packages', 'dist-packages'))
    sources += list((lib / 'lib-dynload').rglob('*.so'))
    deps = set()
    for src in sources:
        out = subprocess.run(['ldd', str(src)], text=True, capture_output=True)
        for line in out.stdout.splitlines():
            for token in line.split():
                if token.startswith('/') and Path(token).is_file(): deps.add(Path(token))
    for src in set(sources[:4]) | deps:
        dest = dst / str(src).lstrip('/'); dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src.resolve(), dest)
    py = dst / 'usr/bin/python3'; py.parent.mkdir(parents=True, exist_ok=True)
    if not py.exists(): py.symlink_to(str(sources[0]))
    rs = dst / 'usr/bin/rsync'
    if not rs.exists(): rs.symlink_to(str(sources[1]))
    for d in ('target', 'boot-target', 'home-target', 'transaction', 'dev', 'proc', 'tmp'):
        (dst / d).mkdir(parents=True, exist_ok=True)
    shutil.copy2(__file__, dst / 'updater.py')
    shutil.copy2(helper, dst / 'bootimg.py')
    # Include NSS configuration for numeric lookup fallbacks; no credentials copied.
    (dst / 'etc').mkdir(exist_ok=True)
    (dst / 'etc/nsswitch.conf').write_text('passwd: files\ngroup: files\n')
    (dst / 'etc/passwd').write_text('root:x:0:0:root:/root:/bin/sh\n')
    (dst / 'etc/group').write_text('root:x:0:\n')


def retarget_kernel(src, dst, rootarg, helper=BOOTIMG):
    import importlib.util
    spec = importlib.util.spec_from_file_location('bootimg', helper)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    image = module.BootImg(src.read_bytes())
    if image.id != image.expected_id(): raise ValueError('KERNEL header checksum mismatch')
    # Older installed helpers only know the bootimg ramdisk.
    initramfs = getattr(module, 'initramfs_bytes', lambda img: module.ramdisk_bytes(img.ramdisk))
    raw = initramfs(image)
    if b'konkr-update-recover' not in raw: raise ValueError('KERNEL has no update recovery hook')
    dst.write_bytes(image.build(module.retarget(image.cmdline, rootarg)))


def package_format(package):
    """2 for a signed package (manifest.sig among the first members), else 1."""
    with tarfile.open(package, 'r:gz') as tf:
        for i, m in enumerate(tf):
            if m.name.removeprefix('./') == 'manifest.sig': return FORMAT2
            if i > 3: break
    return FORMAT


def private_copy(src, dst):
    """A root-owned copy of the package to validate. When the source already
    is one (update-agent's cache: root's, nobody else can write there) on the
    same filesystem, a hard link does: copying 4 GB again took minutes."""
    st, parent = os.lstat(src), os.lstat(src.parent)
    if (not os.path.islink(src) and st.st_uid == 0 and st.st_nlink == 1
            and parent.st_uid == 0 and not parent.st_mode & 0o022
            and st.st_dev == os.lstat(dst.parent).st_dev):
        os.link(src, dst)
    else:
        shutil.copyfile(src, dst)
    os.chmod(dst, 0o600)


def extract_members(package, dest, names):
    """Pull a few members out without reading the rest of the archive (tar
    reads to the end looking for more copies of them)."""
    want = set(names)
    with tarfile.open(package, 'r|gz') as tf:
        for m in tf:
            name = m.name.removeprefix('./')
            if name not in want: continue
            if not m.isfile(): raise ValueError(f'{name} in the update is not a file')
            with tf.extractfile(m) as f, open(dest / name, 'wb') as out:
                shutil.copyfileobj(f, out, 4 << 20)
            want.discard(name)
            if not want: return
    raise ValueError(f'update is missing {", ".join(sorted(want))}')


def stage(args):
    if os.geteuid() != 0: raise ValueError('staging needs administrator access')
    model = Path('/sys/firmware/devicetree/base/model').read_text().rstrip('\0\n')
    if model not in SUPPORTED_MODELS: raise ValueError('unsupported device')
    if os.uname().machine != 'aarch64': raise ValueError('requires ARM64 Zaviya')
    import pwd
    if pwd.getpwnam('steamos').pw_uid != 1000: raise ValueError('unsupported account layout')
    source_package = Path(args.package).resolve()
    expected = (args.sha256 or '').lower()
    if expected and not re.fullmatch('[0-9a-f]{64}', expected): raise ValueError('invalid expected SHA256')
    root_info, home_info, boot_info = [mount_info(x) for x in ('/', '/home', '/boot')]
    if root_info['fstype'] != 'ext4' or home_info['fstype'] != 'ext4' or boot_info['fstype'] != 'vfat':
        raise ValueError('requires separate ext4 root/home and FAT boot filesystems')
    if home_info['source'] == root_info['source']: raise ValueError('HOME must be a separate filesystem')
    pending = Path('/') / PENDING
    if pending.exists(): raise ValueError('an update is already pending; finish or recover it first')
    base = Path('/home/.konkr-updates')
    if base.is_symlink(): raise ValueError('invalid update storage directory')
    base.mkdir(mode=0o700, exist_ok=True)
    if base.stat().st_uid != 0: raise ValueError('update storage is not owned by root')
    os.chmod(base, 0o700)
    work = base / str(uuid.uuid4()); work.mkdir(mode=0o700)
    try:
        # Validate and extract only a private, root-owned copy to avoid input races.
        package = work / 'package.tar.gz'
        private_copy(source_package, package)
        if expected and digest(package) != expected: raise ValueError('package SHA256 mismatch')
        if package_format(package) == FORMAT2:
            if mount_info('/var')['source'] != root_info['source']:
                raise ValueError('a separate /var partition is not supported')
            return stage2(work, package, root_info, home_info, boot_info, model, pending)
        if not expected: raise ValueError('--sha256 is required for this package')
        manifest, size = validate_archive(package)
        # One package per SoC: its KERNEL only boots the models it lists.
        if model not in manifest['devices']:
            raise ValueError(f'this update is for {", ".join(manifest["devices"])}, not {model}')
        used = shutil.disk_usage('/').total - shutil.disk_usage('/').free
        if shutil.disk_usage('/home').free < size + used + (512 << 20):
            raise ValueError('not enough HOME space for payload and rollback backup')
        managed = sum(int(run('du', '-sx', '-B1', '/' + name, capture_output=True,
                             text=True).stdout.split()[0]) for name in ROOT_DIRS)
        if shutil.disk_usage('/').free + managed < size + (512 << 20):
            raise ValueError('root partition is too small for this update')
        payload = work / 'payload'; payload.mkdir()
        run('tar', '--xattrs', '--xattrs-include=*', '--acls', '--numeric-owner', '-xzf', package, '-C', payload)
        verify_payload(payload, manifest)
        info = {'id': work.name, 'version': manifest['version'], 'sha256': expected,
                'root_uuid': root_info['uuid'], 'home_uuid': home_info['uuid'],
                'boot_uuid': boot_info['uuid'], 'manifest': manifest}
        write_json(work / 'transaction.json', info)
        shutil.copy2('/boot/KERNEL', work / 'previous-KERNEL')
        rootarg = next((x[5:] for x in Path('/proc/cmdline').read_text().split() if x.startswith('root=')), '')
        if not rootarg: raise ValueError('cannot identify the boot root argument')
        helper = bootimg_helper(payload)
        retarget_kernel(payload / 'boot/KERNEL', work / 'next-KERNEL', rootarg, helper)
        recovery_runtime(work / 'recovery', helper)
        state(work, 'staged')
        pending.parent.mkdir(parents=True, exist_ok=True)
        pending.write_text(work.name + '\n'); os.chmod(pending, 0o600)
        os.sync()
        # Bootstrap recovery for v1.1 installs; the original boot image is backed up.
        install_kernel(work / 'next-KERNEL', Path('/boot'))
        print('Update staged. Reboot to apply. Backup:', work)
    except BaseException:
        if not pending.exists(): shutil.rmtree(work)
        raise


def staged_ready():
    """The marker is written before the boot image, so it alone does not mean
    the update can be installed by a restart: the new boot image must be in."""
    pending = Path('/' + PENDING)
    if not pending.exists(): return False
    nxt = Path('/home/.konkr-updates') / pending.read_text().strip() / 'next-KERNEL'
    try:
        return not nxt.exists() or digest(nxt) == digest('/boot/KERNEL')
    except OSError:
        return False


def install_kernel(src, boot):
    temp = boot / 'KERNEL.new'
    shutil.copyfile(src, temp)
    with temp.open('rb') as f: os.fsync(f.fileno())
    if digest(temp) != digest(src): raise ValueError('boot copy checksum mismatch')
    os.replace(temp, boot / 'KERNEL')
    (boot / 'KERNEL.md5').write_text(hashlib.md5((boot / 'KERNEL').read_bytes()).hexdigest() + '  KERNEL\n')
    # EFI files for newer OpenABL. The boot service retries if this fails.
    try: subprocess.run(['/usr/lib/steamos-arm/kernel-efi-sync', '--boot', str(boot), '--force'], check=False, timeout=120)
    except (OSError, subprocess.TimeoutExpired): pass
    os.sync()


def snapshot(root, home, work):
    backup = work / 'backup'
    write_json(backup / 'root-presence.json', {rel: (root / rel).exists() for rel in (*ROOT_DIRS, UPPER)})
    for rel in (*ROOT_DIRS, UPPER):
        src = root / rel
        if src.exists(): copy_tree(src, backup / 'root' / rel)
    for rel in HOME_DIRS:
        src = home / 'steamos' / rel
        if src.exists(): copy_tree(src, backup / 'home/steamos' / rel)
    # Explicitly record absent directories so rollback removes newly introduced ones.
    write_json(backup / 'home-presence.json', {rel: (home / 'steamos' / rel).exists() for rel in HOME_DIRS})
    local = home / 'steamos/.local/share/vulkan/implicit_layer.d'
    if local.exists(): copy_tree(local, backup / 'layers')
    write_json(backup / 'layers-presence.json', {'exists': local.exists()})
    os.sync()
    state(work, 'backed-up')


def restore(root, boot, home, work):
    backup = work / 'backup'
    present_root = json.loads((backup / 'root-presence.json').read_text())
    for rel in (*ROOT_DIRS, UPPER):
        src = backup / 'root' / rel
        if present_root[rel]: copy_tree(src, root / rel, delete=True)
        elif (root / rel).exists(): shutil.rmtree(root / rel)
    present = json.loads((backup / 'home-presence.json').read_text())
    for rel in HOME_DIRS:
        dest = home / 'steamos' / rel
        if present[rel]: copy_tree(backup / 'home/steamos' / rel, dest, delete=True)
        elif dest.exists(): shutil.rmtree(dest)
    layers = home / 'steamos/.local/share/vulkan/implicit_layer.d'
    if json.loads((backup / 'layers-presence.json').read_text())['exists']:
        copy_tree(backup / 'layers', layers, delete=True)
    elif layers.exists(): shutil.rmtree(layers)
    os.sync()
    install_kernel(work / 'previous-KERNEL', boot)


def apply(root, boot, home, work, manifest):
    payload = work / 'payload'
    for rel in ('usr', 'opt'): copy_tree(payload / 'root' / rel, root / rel, delete=True)
    # Preserve identity, accounts, network credentials and the target partition layout.
    copy_tree(payload / 'root/etc', root / 'etc', delete=True, excludes=PRESERVE)
    upper = payload / 'root' / UPPER
    if upper.exists(): copy_tree(upper, root / UPPER, excludes=PRESERVE)
    for rel in HOME_DIRS:
        src = payload / 'home/steamos' / rel
        if not src.is_dir(): raise ValueError(f'missing home migration: {rel}')
        copy_tree(src, home / 'steamos' / rel, delete=True)
        # Images stage users with numeric ownership; do not inherit root ownership.
        run('chown', '-R', '1000:1000', home / 'steamos' / rel)
    for prefix in (root / 'usr', root / 'usr/local', home / 'steamos/.local'):
        for name in ('VkLayer_LS_frame_generation.json', 'VkLayer_LS_frame_generation_arm64.json'):
            (prefix / 'share/vulkan/implicit_layer.d' / name).unlink(missing_ok=True)
    # Compare every managed regular file that was installed. No game/save paths included.
    for name, sha in manifest['files'].items():
        if name.startswith(('root/usr/', 'root/opt/')): target = root / name[5:]
        elif any(name.startswith('home/steamos/' + rel + '/') for rel in HOME_DIRS): target = home / name[5:]
        elif name.startswith(('root/etc/', 'root/' + UPPER + '/')):
            prefix = 'root/etc/' if name.startswith('root/etc/') else 'root/' + UPPER + '/'
            rel = name[len(prefix):]
            if any(rel == p or rel.startswith(p + '/') for p in PRESERVE): continue
            target = root / name[5:]
        else: continue
        if digest(target) != sha: raise ValueError(f'installed checksum mismatch: {name}')
    os.sync()
    install_kernel(work / 'next-KERNEL', boot)


# ------------------------------------------------------- format 2: device ---
def real_path(key, root, home, boot=None):
    if key == 'boot/KERNEL': return (boot or Path('/boot')) / 'KERNEL'
    if key.startswith('root/'): return root / key[5:]
    if key.startswith('home/'): return home / key[5:]
    raise ValueError(f'unmanaged path: {key}')


def recorded(root):
    """The install inventory: key -> [size, mtime_ns, sha256] as last written."""
    try: return json.loads((root / INVENTORY).read_text()).get('files', {})
    except (OSError, ValueError): return {}


def record_inventory(root, home, target, boot=None, version=None, soc=None):
    """The install inventory, plus the release it is (version, soc). Without
    a version given, the one already recorded is kept."""
    files = {}
    for key, e in target.items():
        if 'f' in e and key != 'boot/KERNEL':
            try: st = os.lstat(real_path(key, root, home))
            except OSError: continue
            files[key] = [st.st_size, st.st_mtime_ns, e['f'][4]]
    old = recorded_release(root)
    write_json(root / INVENTORY, {'format': FORMAT2, 'files': files,
                                  'version': version or old.get('version', ''),
                                  'soc': soc or old.get('soc', '')})


def recorded_release(root=Path('/')):
    """{'version', 'soc'} of the installed release ({} on images older than v1.3)."""
    try:
        d = json.loads((root / INVENTORY).read_text())
        return {k: d[k] for k in ('version', 'soc') if d.get(k)}
    except (OSError, ValueError):
        return {}


def this_soc():
    try:
        model = Path('/proc/device-tree/model').read_text().strip('\0\n ')
    except OSError:
        return ''
    return next((soc for soc, models in SOC_MODELS.items() if model in models), '')


def make_plan(target, root, home, boot):
    """What turns this system into `target`, touching only what differs."""
    import stat as S
    rec = recorded(root)
    plan = {'mkdir': [], 'write': [], 'link': [], 'whiteout': [], 'meta': [], 'delete': []}
    live = set()
    for prefix in MANAGED:
        base = real_path(prefix, root, home)
        if not base.exists(): continue
        for dirpath, dirs, files in os.walk(base):
            rel = os.path.relpath(dirpath, base)
            key = prefix if rel == '.' else f'{prefix}/{rel}'
            if preserved(key): dirs[:] = []; continue
            live.add(key)
            for name in files + [d for d in dirs if os.path.islink(os.path.join(dirpath, d))]:
                if not preserved(f'{key}/{name}'): live.add(f'{key}/{name}')
            dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(dirpath, d))]
    for key in sorted(target):
        e = target[key]
        p = real_path(key, root, home, boot)
        try: st = os.lstat(p)
        except FileNotFoundError: st = None
        if 'd' in e:
            if st is None or not S.S_ISDIR(st.st_mode): plan['mkdir'].append(key)
            elif [S.S_IMODE(st.st_mode), st.st_uid, st.st_gid] != e['d']: plan['meta'].append(key)
        elif 'l' in e:
            if st is None or not S.S_ISLNK(st.st_mode) or os.readlink(p) != e['l'][0]: plan['link'].append(key)
        elif 'w' in e:
            if st is None or not (S.S_ISCHR(st.st_mode) and st.st_rdev == 0): plan['whiteout'].append(key)
        else:
            mode, uid, gid, size, sha, _x = e['f']
            same = False
            if st is not None and S.S_ISREG(st.st_mode) and st.st_size == size:
                r = rec.get(key)
                same = (r is not None and r[0] == size and r[1] == st.st_mtime_ns and r[2] == sha) or digest(p) == sha
            if not same: plan['write'].append(key)
            elif key != 'boot/KERNEL' and [S.S_IMODE(st.st_mode), st.st_uid, st.st_gid] != [mode, uid, gid]:
                plan['meta'].append(key)
            elif key != 'boot/KERNEL' and xattrs_of(p) != _x: plan['meta'].append(key)
    live.discard('root/' + INVENTORY)                 # rewritten after every update
    # Deleted: longest first, so a directory goes after what was in it.
    plan['delete'] = sorted(live - set(target), key=lambda k: (-k.count('/'), k))
    return plan


# Settings files our own daemons rewrite from Zaviya Control (konkrd puts
# the Pocket FIT's front buttons on controller buttons in this map, issue #64).
# A release only changes one together with its blob; without the blob the
# device's copy is the user's setting and stays.
SETTINGS = tuple(p + 'inputplumber/capability_maps.d/konkr_pocketfit_sysbtn.yaml'
                 for p in ('root/etc/', 'root/' + UPPER + '/'))


def drop_stale_transient(plan, target, blobs, root, home):
    """Python rewrites a .pyc whose source looks newer, and pacman refreshes
    sync databases under /usr/lib/holo/pacmandb/sync/, so live copies can differ
    from the release. When the package doesn't carry them, ignore or delete them
    instead of refusing the update. Settings files keep the user's copy."""
    for key in [k for k in plan['write'] if is_transient(k) and target[k]['f'][4] not in blobs]:
        plan['write'].remove(key)
        if '/__pycache__/' in key and os.path.lexists(real_path(key, root, home)):
            plan['delete'].append(key)
    for key in [k for k in plan['write'] if k in SETTINGS and target[k]['f'][4] not in blobs]:
        if os.path.lexists(real_path(key, root, home)): plan['write'].remove(key)
    plan['delete'].sort(key=lambda k: (-k.count('/'), k))


def plan_keys(plan):
    return [k for kind in ('mkdir', 'write', 'link', 'whiteout', 'meta', 'delete') for k in plan[kind]]


def backup_plan(plan, root, home, work):
    """Copy what the plan will change, nothing else; record what didn't exist."""
    import stat as S
    index = {}
    for key in plan_keys(plan):
        if key == 'boot/KERNEL': continue
        p = real_path(key, root, home)
        try: st = os.lstat(p)
        except FileNotFoundError: index[key] = None; continue
        dst = work / 'backup' / key
        dst.parent.mkdir(parents=True, exist_ok=True)
        if S.S_ISREG(st.st_mode):
            shutil.copy2(p, dst, follow_symlinks=False)
            os.chown(dst, st.st_uid, st.st_gid, follow_symlinks=False)
            index[key] = entry_for(p)
        elif S.S_ISLNK(st.st_mode) or S.S_ISDIR(st.st_mode) or S.S_ISCHR(st.st_mode):
            index[key] = entry_for(p)
        if S.S_ISDIR(st.st_mode) and key in plan['delete']:
            # A deleted directory's contents are in the plan too (walked above).
            pass
    write_json(work / 'backup-index.json', index)
    os.sync()


def put_file(src, dst, e):
    mode, uid, gid, _size, _sha, xattrs = e['f']
    tmp = dst.with_name('.sau-' + dst.name)
    if tmp.exists() or tmp.is_symlink(): tmp.unlink()
    shutil.copyfile(src, tmp)
    os.chown(tmp, uid, gid); os.chmod(tmp, mode)          # chown clears setuid: chmod after
    for name, val in xattrs.items(): os.setxattr(tmp, name, bytes.fromhex(val))
    with open(tmp, 'rb') as f: os.fsync(f.fileno())
    if dst.is_dir() and not dst.is_symlink(): shutil.rmtree(dst)
    os.replace(tmp, dst)


def put_meta(p, e):
    if 'd' in e:
        mode, uid, gid = e['d']; os.chown(p, uid, gid); os.chmod(p, mode)
    elif 'f' in e:
        mode, uid, gid, _s, _h, xattrs = e['f']
        os.chown(p, uid, gid); os.chmod(p, mode)
        have = {n for n in os.listxattr(p) if n.startswith(('security.capability', 'user.'))}
        for name in have - set(xattrs): os.removexattr(p, name)
        for name, val in xattrs.items(): os.setxattr(p, name, bytes.fromhex(val))


def put_link(p, target):
    tmp = p.with_name('.sau-' + p.name)
    if tmp.exists() or tmp.is_symlink(): tmp.unlink()
    os.symlink(target, tmp)
    if p.is_dir() and not p.is_symlink(): shutil.rmtree(p)
    os.replace(tmp, p)


def remove_path(p):
    if p.is_symlink() or not p.is_dir():
        if p.exists() or p.is_symlink(): p.unlink()
    else:
        shutil.rmtree(p)


class Progress:
    """Restart-step progress on the console and in the kernel log."""
    def __init__(self, total):
        self.total, self.done, self.shown = max(total, 1), 0, -1

    def step(self, n=1):
        self.done += n
        pct = self.done * 100 // self.total
        if pct != self.shown:
            self.shown = pct
            line = f'Installing update: {pct}%'
            print(line, flush=True)
            for dev in ('/dev/kmsg', '/dev/console'):
                try:
                    with open(dev, 'w') as f: f.write(('\r' if dev == '/dev/console' else '') + line + ('\n' if dev == '/dev/kmsg' else ''))
                except OSError: pass


def apply2(root, boot, home, work):
    plan = json.loads((work / 'plan.json').read_text())
    target = json.loads((work / 'target.json').read_text())
    blobs = work / 'blobs'
    prog = Progress(len(plan_keys(plan)))
    for key in sorted(plan['mkdir'], key=lambda k: k.count('/')):
        p = real_path(key, root, home)
        if (p.exists() or p.is_symlink()) and (p.is_symlink() or not p.is_dir()): p.unlink()
        p.mkdir(exist_ok=True); put_meta(p, target[key]); prog.step()
    for key in plan['write']:
        if key == 'boot/KERNEL': prog.step(); continue
        e = target[key]
        put_file(blobs / e['f'][4][:2] / e['f'][4], real_path(key, root, home), e); prog.step()
    for key in plan['link']:
        put_link(real_path(key, root, home), target[key]['l'][0]); prog.step()
    for key in plan['whiteout']:
        p = real_path(key, root, home)
        if p.exists() or p.is_symlink(): remove_path(p)
        import stat as S
        os.mknod(p, S.S_IFCHR | 0o000, 0); prog.step()
    for key in plan['meta']:
        put_meta(real_path(key, root, home), target[key]); prog.step()
    for key in plan['delete']:
        remove_path(real_path(key, root, home)); prog.step()
    for key in plan['write']:
        if key == 'boot/KERNEL': continue
        if digest(real_path(key, root, home)) != target[key]['f'][4]:
            raise ValueError(f'installed checksum mismatch: {key}')
    try:
        version = json.loads((work / 'transaction.json').read_text()).get('version')
    except (OSError, ValueError):
        version = None
    record_inventory(root, home, target, version=version)
    os.sync()
    if 'boot/KERNEL' in plan['write']: install_kernel(work / 'next-KERNEL', boot)


def restore2(root, boot, home, work):
    plan = json.loads((work / 'plan.json').read_text())
    index = json.loads((work / 'backup-index.json').read_text())
    keys = [k for k in plan_keys(plan) if k != 'boot/KERNEL']
    # Remove what the update created, then put back what it changed, parents first.
    for key in sorted(keys, key=lambda k: -k.count('/')):
        if index.get(key) is None:
            p = real_path(key, root, home)
            if p.exists() or p.is_symlink(): remove_path(p)
    for key in sorted(keys, key=lambda k: k.count('/')):
        e = index.get(key)
        if e is None: continue
        p = real_path(key, root, home)
        if 'd' in e:
            if p.is_symlink() or (p.exists() and not p.is_dir()): p.unlink()
            p.mkdir(parents=True, exist_ok=True); put_meta(p, e)
        elif 'l' in e: put_link(p, e['l'][0])
        elif 'w' in e:
            if p.exists() or p.is_symlink(): remove_path(p)
            import stat as S
            os.mknod(p, S.S_IFCHR | 0o000, 0)
        else: put_file(work / 'backup' / key, p, e)
    os.sync()
    install_kernel(work / 'previous-KERNEL', boot)


def stage2(work, package, root_info, home_info, boot_info, model, pending):
    """Stage a signed format 2 package: plan against this system, keep only
    the contents the plan needs, back up only what it will change."""
    extract_members(package, work, ('manifest.json', 'manifest.sig'))
    verify_signature(work / 'manifest.json', work / 'manifest.sig')
    manifest = json.loads((work / 'manifest.json').read_text())
    if manifest.get('format') != FORMAT2 or manifest.get('architecture') != 'aarch64':
        raise ValueError('unsupported update format or architecture')
    if model not in manifest.get('devices', []):
        raise ValueError(f'this update is for {", ".join(manifest["devices"])}, not {model}')
    target = manifest['inventory']
    for key in target:
        p = PurePosixPath(key)
        if p.is_absolute() or '..' in p.parts or not (key == 'boot/KERNEL' or any(
                key == m or key.startswith(m + '/') for m in MANAGED)) or preserved(key):
            raise ValueError(f'unsafe path in update: {key}')
    # The root as stored on disk: /etc on SteamOS is an overlay mounted over it.
    view = work / 'rootview'; view.mkdir()
    run('mount', '--bind', '/', view)
    try:
        plan = make_plan(target, view, Path('/home'), Path('/boot'))
        drop_stale_transient(plan, target, set(manifest['blobs']), view, Path('/home'))
        need = {target[k]['f'][4] for k in plan['write']}
        missing = need - set(manifest['blobs'])
        if missing:
            paths = sorted(k for k in plan['write'] if target[k]['f'][4] in missing)
            shown = ', '.join('/' + k.split('/', 1)[1] if k.startswith('root/') else k for k in paths[:5])
            raise ValueError('this system differs from the releases this update was made for '
                             f'({", ".join(manifest.get("from") or ["?"])}): {shown}'
                             + (f' and {len(paths) - 5} more' if len(paths) > 5 else '')
                             + ' changed; install the full update')
        listing = work / 'blobs.list'
        listing.write_text(''.join(f'blobs/{h[:2]}/{h}\n' for h in sorted(need)))
        if need: run('tar', '-xzf', package, '-C', work, '-T', listing)
        for h in need:
            if digest(work / 'blobs' / h[:2] / h) != h: raise ValueError(f'damaged update content {h}')
        add = sum(target[k]['f'][3] for k in plan['write'] if k != 'boot/KERNEL')
        if shutil.disk_usage('/').free < add + (256 << 20): raise ValueError('not enough space on the system partition')
        write_json(work / 'plan.json', plan)
        write_json(work / 'target.json', target)
        backup_plan(plan, view, Path('/home'), work)
    finally:
        run('umount', view)
        view.rmdir()
    (work / 'package.tar.gz').unlink()
    shutil.copy2('/boot/KERNEL', work / 'previous-KERNEL')
    helper = BOOTIMG
    if 'boot/KERNEL' in plan['write']:
        h = target['boot/KERNEL']['f'][4]
        rootarg = next((x[5:] for x in Path('/proc/cmdline').read_text().split() if x.startswith('root=')), '')
        if not rootarg: raise ValueError('cannot identify the boot root argument')
        retarget_kernel(work / 'blobs' / h[:2] / h, work / 'next-KERNEL', rootarg, helper)
    n = len(plan_keys(plan))
    info = {'id': work.name, 'format': FORMAT2, 'version': manifest['version'],
            'root_uuid': root_info['uuid'], 'home_uuid': home_info['uuid'],
            'boot_uuid': boot_info['uuid'], 'changes': n}
    write_json(work / 'transaction.json', info)
    recovery_runtime(work / 'recovery', helper)
    state(work, 'backed-up')
    pending.parent.mkdir(parents=True, exist_ok=True)
    pending.write_text(work.name + '\n'); os.chmod(pending, 0o600)
    os.sync()
    if (work / 'next-KERNEL').exists(): install_kernel(work / 'next-KERNEL', Path('/boot'))
    print(f'Update {manifest["version"]} staged: {n} changes. Restart to install.')


def recover(args):
    if os.geteuid() != 0: raise ValueError('recovery needs administrator access')
    root, boot, home, work = map(Path, (args.root, args.boot, args.home, args.work))
    if work.stat().st_uid != 0: raise ValueError('transaction is not owned by root')
    os.environ['PATH'] = '/usr/bin:/usr/sbin:/bin:/sbin'
    record = json.loads((work / 'transaction.json').read_text())
    for path, key in ((root, 'root_uuid'), (home, 'home_uuid'), (boot, 'boot_uuid')):
        expected = record.get(key)
        if not expected or mount_info(str(path)).get('uuid') != expected:
            raise ValueError(f'{key} does not match the staged installation')
    pending = root / PENDING
    if not pending.exists() or pending.read_text().strip() != record['id']:
        raise ValueError('transaction does not match this root filesystem')
    current = json.loads((work / 'state.json').read_text())['state']
    if record.get('format') == FORMAT2:
        return recover2(root, boot, home, work, pending, current)
    if current == 'committed':
        pending.unlink(); os.sync(); return 0
    if current == 'rolled-back':
        pending.unlink(); os.sync(); return 10
    if current == 'staged':
        try:
            verify_payload(work / 'payload', record['manifest'])
            snapshot(root, home, work)
            current = 'backed-up'
        except Exception as e:
            print('RECOVERY ERROR:', e, flush=True)
            (work / 'failure.txt').write_text(str(e) + '\n')
            install_kernel(work / 'previous-KERNEL', boot)
            state(work, 'aborted')
            pending.unlink(); os.sync(); return 10
    if current == 'backed-up':
        try:
            state(work, 'applying')
            apply(root, boot, home, work, record['manifest'])
            state(work, 'committed')
            pending.unlink(); os.sync(); return 0
        except Exception as e:
            print('RECOVERY ERROR:', e, flush=True)
            (work / 'failure.txt').write_text(str(e) + '\n')
            current = 'applying'
    if current in ('applying', 'rolling-back', 'rollback-requested'):
        state(work, 'rolling-back')
        restore(root, boot, home, work)
        state(work, 'rolled-back')
        pending.unlink(); os.sync(); return 10
    raise ValueError(f'cannot recover state: {current}')


def recover2(root, boot, home, work, pending, current):
    if current == 'committed':
        pending.unlink(); os.sync(); return 0
    if current in ('rolled-back', 'aborted'):
        pending.unlink(); os.sync(); return 10
    if current == 'backed-up':
        try:
            state(work, 'applying')
            apply2(root, boot, home, work)
            state(work, 'committed')
            pending.unlink(); os.sync(); return 0
        except Exception as e:
            print('RECOVERY ERROR:', e, flush=True)
            (work / 'failure.txt').write_text(str(e) + '\n')
            current = 'applying'
    if current in ('applying', 'rolling-back', 'rollback-requested'):
        state(work, 'rolling-back')
        restore2(root, boot, home, work)
        state(work, 'rolled-back')
        pending.unlink(); os.sync(); return 10
    raise ValueError(f'cannot recover state: {current}')


# What a finished transaction keeps: enough to tell what happened.
KEEP = {'transaction.json', 'state.json', 'failure.txt'}
FINISHED = {'committed', 'rolled-back', 'aborted'}


def cleanup():
    """Free HOME from finished updates. Each transaction keeps its download's
    contents, a backup, a recovery runtime and two boot images (gigabytes for
    a full package) that nothing needs once it has committed or rolled back.
    Keep only the records of those; drop transactions that never got as far
    as being staged. The pending one, and anything with a mount inside, stay."""
    base = Path('/home/.konkr-updates')
    if base.is_symlink() or not base.is_dir() or base.stat().st_uid != 0: return 0
    pending = Path('/' + PENDING)
    keep_id = pending.read_text().strip() if pending.exists() else None
    mounts = [l.split()[4] for l in Path('/proc/self/mountinfo').read_text().splitlines()]
    freed = 0
    for work in base.iterdir():
        if work.is_symlink() or not work.is_dir() or work.name == keep_id: continue
        if any(m == str(work) or m.startswith(str(work) + '/') for m in mounts): continue
        try: current = json.loads((work / 'state.json').read_text())['state']
        except (OSError, ValueError, KeyError): current = None
        if current in FINISHED:
            gone = [x for x in work.iterdir() if x.name not in KEEP and not x.name.endswith('.log')]
        elif current is None:
            gone = [work]                       # staging stopped before it was recorded
        else:
            continue                            # mid-update without a pending marker: leave it
        for x in gone:
            freed += int(run('du', '-sxB1', str(x), capture_output=True, text=True).stdout.split()[0] or 0)
            if x.is_dir() and not x.is_symlink(): shutil.rmtree(x)
            else: x.unlink()
    if freed: print(f'freed {freed >> 20} MiB of finished updates')
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest='command', required=True)
    p = sub.add_parser('stage'); p.add_argument('package'); p.add_argument('--sha256')
    p = sub.add_parser('record-inventory', help='write the install inventory of a built rootfs')
    p.add_argument('--root', required=True)
    p.add_argument('--version', default='')
    p.add_argument('--soc', default='')
    sub.add_parser('status', help='installed release and whether an update is staged (JSON)')
    sub.add_parser('cleanup', help='remove what finished updates left on HOME')
    p = sub.add_parser('recover')
    for name in ('root', 'boot', 'home', 'work'): p.add_argument('--' + name, required=True)
    p = sub.add_parser('inspect'); p.add_argument('package')
    a = ap.parse_args()
    try:
        if a.command == 'stage':
            with open('/run/konkr-update.lock', 'w') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB); cleanup(); stage(a)
        elif a.command == 'cleanup':
            if os.geteuid() != 0: raise ValueError('cleanup needs administrator access')
            with open('/run/konkr-update.lock', 'w') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB); return cleanup()
        elif a.command == 'recover': return recover(a)
        elif a.command == 'record-inventory':
            root = Path(a.root)
            def base_of(prefix): return root / prefix.split('/', 1)[1] if prefix.startswith('root/') else root / prefix
            inv = walk_managed(base_of, skip_etc=True); inv.pop('root/' + INVENTORY, None)
            record_inventory(root, root / 'home', inv, version=a.version or None, soc=a.soc or None)
            print(f'{root / INVENTORY}: {sum(1 for e in inv.values() if "f" in e)} files')
        elif a.command == 'status':
            rel = recorded_release()
            # The device's own model decides the SoC (the REDMAGIC 6 shares this
            # rootfs but no update package fits it, so it gets none).
            print(json.dumps({'version': rel.get('version', ''), 'soc': this_soc(),
                              'staged': staged_ready()}))
        else:
            m, size = validate_archive(a.package); print(json.dumps({'version': m['version'], 'bytes': size}, indent=2))
    except Exception as e:
        print('ERROR:', e, file=sys.stderr); return 1
    return 0


if __name__ == '__main__': sys.exit(main())
