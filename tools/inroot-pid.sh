#!/bin/bash
# like inroot.sh, but inside a private PID namespace: every process started in
# the chroot is killed when the command returns.
ROOT=$(readlink -f "$1"); shift
exec sudo unshare --mount --propagation private --ipc --uts --pid --fork --kill-child -- /bin/bash -c '
set -e
ROOT="$1"; shift
hostname gbook-build
mount -t proc proc "$ROOT/proc"
mount -t tmpfs -o mode=755,nosuid tmpfs "$ROOT/dev"
for n in null zero full random urandom tty; do : > "$ROOT/dev/$n"; mount --bind /dev/$n "$ROOT/dev/$n"; done
mkdir -p "$ROOT/dev/shm"; mount -t tmpfs tmpfs "$ROOT/dev/shm"
mount -t tmpfs tmpfs "$ROOT/run"
ln -s /proc/self/fd "$ROOT/dev/fd"
exec chroot "$ROOT" /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM=dumb LC_ALL=C.UTF-8 "$@"
' _ "$ROOT" "$@"
