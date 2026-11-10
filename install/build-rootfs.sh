#!/bin/bash
# build-rootfs.sh — build the Galaxy Book 10.6 root filesystem image on a
# Debian/Ubuntu build host. Result: a tar.zst that is unpacked onto the
# tablet's eMMC during installation.
#
#   ./build-rootfs.sh <workdir> [output.tar.zst]
#
# Uses sudo for the chroot. The work directory holds a root-owned tree and
# is removed again at the end unless KEEP_ROOT=1.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT=$(dirname "$HERE")
WORK=${1:?usage: build-rootfs.sh <workdir> [output.tar.zst]}
OUT=${2:-$PROJECT/image/gbook-forky-rootfs.tar.zst}
# GB_PUBLIC=1 (default): image for publication (no SSH key, SSH server off,
# the installer asks for the user's password).
# GB_PUBLIC=0: personal image: PUBKEY (default ~/.ssh/id_ed25519.pub) may log
# in over SSH, sudo without password, the password stays locked.
# GB_USER: desktop user (default gbook), GB_HOSTNAME: host name (default gbook)
GB_PUBLIC=${GB_PUBLIC:-1}
GB_USER=${GB_USER:-gbook}
if [ "$GB_PUBLIC" = 1 ]; then
	PUBKEY=${PUBKEY:-}
else
	PUBKEY=${PUBKEY-$HOME/.ssh/id_ed25519.pub}
fi
GB_HOSTNAME=${GB_HOSTNAME:-gbook}
ARTIFACTS=https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/dist-amd64/forky

ROOT="$WORK/root"
mkdir -p "$WORK" "$(dirname "$OUT")"
if [ -n "$PUBKEY" ] && [ ! -r "$PUBKEY" ]; then
	echo "missing SSH public key $PUBKEY" >&2; exit 1
fi
[ ! -e "$ROOT" ] || { echo "$ROOT already exists, remove it first" >&2; exit 1; }

echo "==> official Debian forky root filesystem"
want=$(curl -fsSL --max-time 30 "$ARTIFACTS/oci/manifest.json" |
	python3 -I -c 'import sys,json; print(json.load(sys.stdin)[0]["Layers"][0].split("/")[-1])')
curl -fL --max-time 600 -sS "$ARTIFACTS/oci/blobs/rootfs.tar.gz" -o "$WORK/rootfs.tar.gz"
got=$(sha256sum "$WORK/rootfs.tar.gz" | cut -d' ' -f1)
[ "$want" = "$got" ] || { echo "digest mismatch: want $want got $got" >&2; exit 1; }
echo "    digest OK $got"
mkdir -p "$ROOT"
sudo tar -xzf "$WORK/rootfs.tar.gz" -C "$ROOT" --numeric-owner

echo "==> staging setup files"
sudo mkdir -p "$ROOT/root/gbook-setup"
sudo cp -r "$PROJECT/bundle" "$ROOT/root/gbook-setup/bundle"
sudo cp "$HERE/chroot-setup.sh" "$HERE/pkglist.txt" "$ROOT/root/gbook-setup/"
if [ -n "$PUBKEY" ]; then
	sudo cp "$PUBKEY" "$ROOT/root/gbook-setup/authorized_keys"
fi

echo "==> configuring inside the chroot (log: $WORK/chroot-setup.log)"
"$PROJECT/tools/inroot.sh" "$ROOT" /usr/bin/env GB_USER="$GB_USER" GB_HOSTNAME="$GB_HOSTNAME" GB_PUBLIC="$GB_PUBLIC" \
	/bin/bash /root/gbook-setup/chroot-setup.sh >"$WORK/chroot-setup.log" 2>&1 ||
	{ echo "chroot setup FAILED, see $WORK/chroot-setup.log" >&2; tail -20 "$WORK/chroot-setup.log" >&2; exit 1; }
grep -E '^==>' "$WORK/chroot-setup.log" | sed 's/^/    /'
tail -8 "$WORK/chroot-setup.log" | sed 's/^/    /'

# keep the support bundle on the tablet for later re-installs
sudo mkdir -p "$ROOT/opt/gbook"
sudo rm -rf "$ROOT/opt/gbook/bundle"
sudo mv "$ROOT/root/gbook-setup/bundle" "$ROOT/opt/gbook/bundle"
sudo install -D -m 755 "$PROJECT/tools/gbook-diag.sh" "$ROOT/opt/gbook/tools/gbook-diag.sh"
sudo rm -rf "$ROOT/root/gbook-setup"

echo "==> packing $OUT"
sudo tar --numeric-owner --xattrs --xattrs-include='*' --acls --one-file-system -C "$ROOT" \
	--exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' --exclude='./run/*' --exclude='./tmp/*' \
	-cf - . | zstd -T0 -10 -q -o "$OUT.tmp" -f
mv "$OUT.tmp" "$OUT"
sha256sum "$OUT" | tee "$OUT.sha256"
# read by the installer: whom to ask a password for
printf 'GB_USER=%s\nGB_PUBLIC=%s\n' "$GB_USER" "$GB_PUBLIC" >"${OUT%.tar.zst}.info"
echo "    size: $(du -h "$OUT" | cut -f1), unpacked: $(sudo du -sxh "$ROOT" | cut -f1)"

if [ "${KEEP_ROOT:-0}" != 1 ]; then
	if findmnt -rn | grep -q "$ROOT"; then
		echo "mounts still present under $ROOT, not removing" >&2
	else
		sudo rm -rf --one-file-system "$ROOT"
	fi
	rm -f "$WORK/rootfs.tar.gz"
fi
echo "==> done"
