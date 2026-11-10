#!/bin/bash
# usage: inroot.sh <rootdir> <command...>
# Runs a command inside the chroot within a private mount namespace (mounts disappear on exit).
ROOT=$(readlink -f "$1"); shift
exec sudo unshare --mount --propagation private --ipc --uts -- /bin/bash -c '
set -e
ROOT="$1"; shift
hostname gbook-build
mount -t proc proc "$ROOT/proc"
mount -t tmpfs -o mode=755,nosuid tmpfs "$ROOT/dev"
for n in null zero full random urandom tty; do : > "$ROOT/dev/$n"; mount --bind /dev/$n "$ROOT/dev/$n"; done
mkdir -p "$ROOT/dev/shm"; mount -t tmpfs tmpfs "$ROOT/dev/shm"
ln -s /proc/self/fd "$ROOT/dev/fd"; ln -s /proc/self/fd/0 "$ROOT/dev/stdin"; ln -s /proc/self/fd/1 "$ROOT/dev/stdout"; ln -s /proc/self/fd/2 "$ROOT/dev/stderr"
cat /etc/resolv.conf > "$ROOT/etc/resolv.conf"
exec chroot "$ROOT" /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM=dumb DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 "$@"
' _ "$ROOT" "$@"
