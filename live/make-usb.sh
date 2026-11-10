#!/bin/bash
# make-usb.sh — build the Galaxy Book 10.6 installer USB on a Linux PC:
# SystemRescue live system + Wi-Fi/SSH helper + the prepared Debian image.
#
# The live settings come from sysrescue.d/: 500-gbook-public.yaml for a public
# root image (GB_PUBLIC=1 in its .info file), 500-gbook.yaml (made from
# 500-gbook-ssh.yaml.example, holds your SSH key) for a personal one.
#
#   make-usb.sh stage                      build live/stage from the ISO and project files
#   make-usb.sh image FILE [SIZE_MB]       write the stage into a raw disk image (VM tests)
#   make-usb.sh write /dev/disk/by-id/usb-...   write the stage to a USB stick (ERASES IT)
#
# "write" only accepts a /dev/disk/by-id/usb-* path so that a device cannot be
# picked by a shifting sdX name.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT=$(dirname "$HERE")
ISO=${ISO:-$HERE/iso/systemrescue-13.03-amd64.iso}
LABEL=RESCUE1303
STAGE=$HERE/stage
ROOT_IMAGE=${ROOT_IMAGE:-$PROJECT/image/gbook-forky-rootfs.tar.zst}

say() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

cmd_stage() {
	[ -f "$ISO" ] || die "ISO not found: $ISO"
	[ -f "$ROOT_IMAGE" ] || die "root image not found: $ROOT_IMAGE"
	local vol info yaml
	info="${ROOT_IMAGE%.tar.zst}.info"
	if [ -f "$info" ] && grep -qx 'GB_PUBLIC=0' "$info"; then
		yaml=$HERE/sysrescue.d/500-gbook.yaml
		[ -f "$yaml" ] || die "personal image: create $yaml from 500-gbook-ssh.yaml.example"
	else
		yaml=$HERE/sysrescue.d/500-gbook-public.yaml
	fi
	vol=$(xorriso -indev "$ISO" -pvd_info 2>/dev/null | awk -F': ' '/^Volume Id/ {print $2}' | tr -d ' ')
	[ "$vol" = "$LABEL" ] || die "ISO label is '$vol', expected $LABEL (update LABEL for another release)"
	say "extracting $(basename "$ISO")"
	rm -rf "$STAGE"
	mkdir -p "$STAGE"
	xorriso -osirrox on -indev "$ISO" -extract / "$STAGE" >/dev/null 2>&1
	chmod -R u+w "$STAGE"
	[ -f "$STAGE/EFI/boot/bootx64.efi" ] || die "extracted tree has no EFI boot loader"

	say "adding installer files"
	install -m 644 "$yaml" "$STAGE/sysrescue.d/500-gbook.yaml"
	mkdir -p "$STAGE/autorun" "$STAGE/gbook"
	install -m 755 "$HERE/autorun/gbook-live.sh" "$STAGE/autorun/gbook-live.sh"
	install -m 755 "$HERE/gbook/gbook-install.sh" "$STAGE/gbook/gbook-install.sh"
	install -m 755 "$PROJECT/tools/gbook-diag.sh" "$STAGE/gbook/gbook-diag.sh"
	cp "$ROOT_IMAGE" "$STAGE/gbook/"
	[ ! -f "$info" ] || cp "$info" "$STAGE/gbook/"
	(cd "$STAGE/gbook" && sha256sum "$(basename "$ROOT_IMAGE")" >"$(basename "$ROOT_IMAGE").sha256")
	# shorter boot menu wait (the menu is shown sideways on the tablet)
	sed -i 's/set timeout=30/set timeout=5/' "$STAGE/boot/grub/grubsrcd.cfg"

	say "manifest"
	(cd "$STAGE" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum >"$STAGE/gbook/MANIFEST.sha256")
	echo "    files: $(wc -l <"$STAGE/gbook/MANIFEST.sha256"), size: $(du -sh "$STAGE" | cut -f1)"
}

# populate <partition device>
populate() {
	local part=$1 mnt need have skip_image=0
	[ -d "$STAGE/sysresccd" ] || die "no stage tree, run: make-usb.sh stage"
	mnt=$(mktemp -d)
	sudo mount -o uid="$(id -u)",gid="$(id -g)" "$part" "$mnt"
	need=$(du -sm "$STAGE" | cut -f1)
	have=$(df -m --output=avail "$mnt" | tail -n1 | tr -d ' ')
	if [ "$need" -gt "$((have - 20))" ]; then
		skip_image=1
		echo "    medium too small for the Debian image ($need MB needed, $have MB free): copying the live system only"
	fi
	say "copying files"
	if [ "$skip_image" = 1 ]; then
		rsync -r --inplace --exclude 'gbook/*.tar.zst' --exclude 'gbook/*.tar.zst.sha256' "$STAGE"/ "$mnt"/
	else
		rsync -r --inplace "$STAGE"/ "$mnt"/
	fi
	sync
	say "verifying"
	local bad=0
	if [ "$skip_image" = 1 ]; then
		(cd "$mnt" && grep -v 'gbook/.*\.tar\.zst' gbook/MANIFEST.sha256 | sha256sum -c --quiet -) || bad=1
	else
		(cd "$mnt" && sha256sum -c --quiet gbook/MANIFEST.sha256) || bad=1
	fi
	sudo umount "$mnt"
	rmdir "$mnt"
	[ "$bad" = 0 ] || die "verification FAILED: the medium does not match the stage"
	echo "    all files verified"
}

cmd_image() {
	local file=${1:?image file name} size=${2:-3072} loop
	say "disk image $file (${size} MB)"
	rm -f "$file"
	truncate -s "${size}M" "$file"
	parted -s "$file" mklabel msdos mkpart primary fat32 1MiB 100% set 1 boot on
	loop=$(sudo losetup -P --find --show "$file")
	trap 'sudo losetup -d "$loop" 2>/dev/null || true' EXIT
	sudo udevadm settle
	sudo mkfs.vfat -F 32 -n "$LABEL" "${loop}p1" >/dev/null
	populate "${loop}p1"
	sudo losetup -d "$loop"
	trap - EXIT
	say "done: $file"
}

cmd_write() {
	local byid=${1:?usage: make-usb.sh write /dev/disk/by-id/usb-...} dev name tran rm size model vendor part
	case "$byid" in
	/dev/disk/by-id/usb-*) ;;
	*) die "give the stick as /dev/disk/by-id/usb-... (see: ls -l /dev/disk/by-id/ | grep usb)" ;;
	esac
	[ -e "$byid" ] || die "$byid does not exist"
	dev=$(readlink -f "$byid")
	name=$(basename "$dev")
	[ "$(lsblk -dn -o TYPE "$dev")" = "disk" ] || die "$dev is not a whole disk"
	tran=$(lsblk -dn -o TRAN "$dev" | tr -d ' ')
	rm=$(lsblk -dn -o RM "$dev" | tr -d ' ')
	size=$(lsblk -dnb -o SIZE "$dev" | tr -d ' ')
	model=$(lsblk -dn -o MODEL "$dev")
	vendor=$(lsblk -dn -o VENDOR "$dev")
	[ "$tran" = "usb" ] || die "$dev is not a USB device (tran=$tran)"
	[ "$rm" = "1" ] || die "$dev is not removable"
	case "$vendor $model" in
	*NanoKVM*|*sipeed*|*Sipeed*) die "$dev is the NanoKVM virtual disk, refusing" ;;
	esac
	[ "$size" -ge $((1900 * 1024 * 1024)) ] || die "$dev is too small or reports no medium ($size bytes)"
	[ "$size" -le $((300 * 1024 * 1024 * 1024)) ] || die "$dev is larger than 300 GB, refusing"
	if findmnt -rn -o SOURCE,TARGET | awk -v d="$dev" 'index($1, d) == 1 && ($2 == "/" || $2 ~ /^\/(boot|home|usr|var)/) {found = 1} END {exit !found}'; then
		die "$dev carries a mounted system file system, refusing"
	fi
	say "target: $dev  ($vendor $model, $((size / 1024 / 1024)) MB)"
	lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$dev"
	for part in $(lsblk -ln -o NAME "$dev" | tail -n +2); do
		if findmnt -rn "/dev/$part" >/dev/null 2>&1 || findmnt -rn -S "/dev/$part" >/dev/null 2>&1; then
			sudo umount "/dev/$part" 2>/dev/null || udisksctl unmount -b "/dev/$part" >/dev/null 2>&1 || die "could not unmount /dev/$part"
		fi
	done
	say "partitioning (MBR, one FAT32 partition, label $LABEL)"
	sudo wipefs -a "$dev" >/dev/null
	sudo parted -s "$dev" mklabel msdos mkpart primary fat32 1MiB 100% set 1 boot on
	sudo partprobe "$dev"
	sudo udevadm settle
	sleep 1
	case "$name" in
	*[0-9]) part="${dev}p1" ;;
	*) part="${dev}1" ;;
	esac
	[ -b "$part" ] || die "partition $part did not appear"
	sudo mkfs.vfat -F 32 -n "$LABEL" "$part" >/dev/null
	populate "$part"
	sync
	say "done: the stick can be removed"
}

case "${1:-}" in
stage) cmd_stage ;;
image) shift; cmd_image "$@" ;;
write) shift; cmd_write "$@" ;;
*) sed -n '2,11p' "$0"; exit 2 ;;
esac
