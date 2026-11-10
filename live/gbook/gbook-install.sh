#!/bin/bash
# gbook-install.sh — put the prepared Debian image on the internal eMMC of the
# Samsung Galaxy Book 10.6. Run as root in the live rescue system.
#
#   !!  DESTROYS ALL DATA ON THE TARGET DISK (Windows included)  !!
#
#   gbook-install.sh [--disk /dev/mmcblkN] [--image FILE] [--yes] [--force]
#                    [--no-wifi-copy] [--password-file FILE]
#
#   --disk DEV       target disk (default: the single internal eMMC)
#   --image FILE     root image *.tar.zst (default: gbook/ on the boot medium)
#   --yes            do not ask for the ERASE confirmation
#   --force          skip the Galaxy Book 10.6 model check (tests on other machines)
#   --no-wifi-copy   do not copy the live system's Wi-Fi profiles to the new system
#   --password-file FILE  password of the desktop user (first line) for public
#                    images; without it the installer asks for one
set -euo pipefail

DISK=""
IMAGE=""
YES=0
FORCE=0
COPY_WIFI=1
PASSFILE=""
PASS=""
MNT=/mnt/gbook-target
USBMNT=/mnt/gbook-usb
LOG=/root/gbook-install.log

while [ $# -gt 0 ]; do
	case "$1" in
	--disk) DISK=${2:?--disk needs a device}; shift 2 ;;
	--image) IMAGE=${2:?--image needs a file}; shift 2 ;;
	--yes) YES=1; shift ;;
	--force) FORCE=1; shift ;;
	--no-wifi-copy) COPY_WIFI=0; shift ;;
	--password-file) PASSFILE=${2:?--password-file needs a file}; shift 2 ;;
	-h|--help) sed -n '2,18p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
exec > >(tee -a "$LOG") 2>&1
echo "=== gbook-install $(date '+%F %T') ==="

say() { echo; echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

for t in sgdisk wipefs partprobe mkfs.vfat mkfs.ext4 zstd tar blkid lsblk findmnt chroot sha256sum udevadm; do
	command -v "$t" >/dev/null 2>&1 || die "required tool missing: $t"
done

# ---------------------------------------------------------------- model check
product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
case "$product" in
"Galaxy Book 10.6"*) echo "model: $product" ;;	# Wi-Fi model, or "Galaxy Book 10.6 LTE"
*)
	[ "$FORCE" = 1 ] || die "this machine is '$product', not a Galaxy Book 10.6 (use --force only for tests)"
	echo "WARNING: model is '$product', continuing because of --force" ;;
esac

# --------------------------------------------------------------- root image
find_image() {
	local d f part
	for d in /run/archiso/bootmnt/gbook "$USBMNT/gbook"; do
		for f in "$d"/*.tar.zst; do
			[ -f "$f" ] && { echo "$f"; return 0; }
		done
	done
	# boot medium not mounted (copytoram): look for it by label
	for part in /dev/disk/by-label/RESCUE*; do
		[ -e "$part" ] || continue
		mkdir -p "$USBMNT"
		findmnt -rn "$USBMNT" >/dev/null || mount -o ro "$part" "$USBMNT" || continue
		for f in "$USBMNT"/gbook/*.tar.zst; do
			[ -f "$f" ] && { echo "$f"; return 0; }
		done
	done
	return 1
}
if [ -z "$IMAGE" ]; then
	IMAGE=$(find_image) || die "no root image found on the boot medium, pass --image FILE"
fi
[ -f "$IMAGE" ] || die "image $IMAGE not found"

say "verifying image $IMAGE"
if [ -f "$IMAGE.sha256" ]; then
	want=$(awk '{print $1; exit}' "$IMAGE.sha256")
	got=$(sha256sum "$IMAGE" | awk '{print $1}')
	[ "$want" = "$got" ] || die "image checksum mismatch (want $want, got $got)"
	echo "    sha256 OK"
else
	echo "    no .sha256 file next to the image, testing the archive instead"
	zstd -t "$IMAGE" || die "image is corrupt"
fi

# ------------------------------------------------- desktop user (public image)
# A public image has no password and no SSH key for its user; the password
# is chosen here, before anything is erased.
IMG_USER=""
IMG_PUBLIC=0
INFO="${IMAGE%.tar.zst}.info"
if [ -f "$INFO" ]; then
	IMG_USER=$(sed -n 's/^GB_USER=\([a-z_][a-z0-9_-]*\)$/\1/p' "$INFO" | head -n1)
	IMG_PUBLIC=$(sed -n 's/^GB_PUBLIC=\([01]\)$/\1/p' "$INFO" | head -n1)
fi
if [ "$IMG_PUBLIC" = 1 ] && [ -n "$IMG_USER" ]; then
	say "password for the desktop user '$IMG_USER'"
	if [ -n "$PASSFILE" ]; then
		IFS= read -r PASS <"$PASSFILE" || true
	else
		while :; do
			IFS= read -r -s -p "New password: " PASS </dev/tty; echo
			IFS= read -r -s -p "Repeat it:    " pass2 </dev/tty; echo
			if [ "$PASS" != "$pass2" ]; then echo "    the two entries differ, again"; continue; fi
			if [ "${#PASS}" -lt 4 ]; then echo "    at least 4 characters, again"; continue; fi
			break
		done
		unset pass2
	fi
	[ "${#PASS}" -ge 4 ] || die "no usable password (at least 4 characters)"
	echo "    password accepted (needed for sudo; the desktop still logs in automatically)"
fi

# -------------------------------------------------------------- target disk
boot_src=$(findmnt -rn -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)
boot_disk=""
[ -n "$boot_src" ] && boot_disk=$(lsblk -no PKNAME "$boot_src" 2>/dev/null | head -n1 || true)

if [ -z "$DISK" ]; then
	mapfile -t cands < <(lsblk -dnb -o NAME,TYPE,SIZE | awk '$2=="disk" && $1 ~ /^mmcblk[0-9]+$/ && $3 >= 30*1024*1024*1024 {print $1}')
	if [ "${#cands[@]}" -ne 1 ]; then
		lsblk -o NAME,SIZE,TYPE,TRAN,RM,MODEL
		die "could not pick the internal eMMC automatically (${#cands[@]} candidates), pass --disk /dev/..."
	fi
	DISK=/dev/${cands[0]}
fi
[ -b "$DISK" ] || die "$DISK is not a block device"
[ "$(lsblk -dn -o TYPE "$DISK")" = "disk" ] || die "$DISK is not a whole disk"
dname=$(basename "$DISK")
[ "$dname" != "$boot_disk" ] || die "$DISK is the boot medium"
case "$dname" in
*[0-9]) P1="${DISK}p1"; P2="${DISK}p2" ;;
*) P1="${DISK}1"; P2="${DISK}2" ;;
esac
size_bytes=$(lsblk -dnb -o SIZE "$DISK")
[ "$size_bytes" -ge $((8 * 1024 * 1024 * 1024)) ] || die "$DISK is smaller than 8 GB"

say "target disk"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,MODEL "$DISK"
echo
echo "ALL DATA ON $DISK WILL BE ERASED."
if [ "$YES" != 1 ]; then
	read -r -p "Type ERASE to continue: " answer </dev/tty
	[ "$answer" = "ERASE" ] || die "aborted, nothing was changed"
fi

# ------------------------------------------------------------- partitioning
say "partitioning $DISK"
swapoff -a 2>/dev/null || true
for m in $(findmnt -rn -o TARGET,SOURCE | awk -v d="$DISK" 'index($2, d) == 1 {print $1}' | sort -r); do
	umount "$m" || die "could not unmount $m"
done
for p in $(lsblk -ln -o NAME "$DISK" | tail -n +2); do
	wipefs -a "/dev/$p" >/dev/null 2>&1 || true
done
wipefs -a "$DISK" >/dev/null
sgdisk --zap-all "$DISK" >/dev/null
sgdisk -n 1:1MiB:+512MiB -t 1:ef00 -c 1:EFI -n 2:0:0 -t 2:8304 -c 2:gbook-root "$DISK"
partprobe "$DISK"
udevadm settle
sleep 1
[ -b "$P1" ] && [ -b "$P2" ] || die "partitions $P1 / $P2 did not appear"

say "creating file systems"
mkfs.vfat -F 32 -n GBOOK-EFI "$P1" >/dev/null
mkfs.ext4 -q -F -L gbook-root "$P2"

say "unpacking the image (a few minutes)"
mkdir -p "$MNT"
mount "$P2" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "$P1" "$MNT/boot/efi"
zstd -dc "$IMAGE" | tar --numeric-owner --xattrs --xattrs-include='*' --acls -xpf - -C "$MNT"
sync

say "fstab"
root_uuid=$(blkid -s UUID -o value "$P2")
efi_uuid=$(blkid -s UUID -o value "$P1")
[ -n "$root_uuid" ] && [ -n "$efi_uuid" ] || die "could not read partition UUIDs"
cat >"$MNT/etc/fstab" <<EOF
# <file system>                           <mount point>  <type>  <options>                   <dump> <pass>
UUID=$root_uuid /              ext4    errors=remount-ro,noatime   0      1
UUID=$efi_uuid                            /boot/efi      vfat    umask=0077                  0      1
EOF
cat "$MNT/etc/fstab"

if [ "$COPY_WIFI" = 1 ] && [ -d /etc/NetworkManager/system-connections ]; then
	say "copying Wi-Fi profiles from the live system"
	n=0
	for f in /etc/NetworkManager/system-connections/*; do
		[ -f "$f" ] || continue
		grep -q '^type=wifi' "$f" || continue
		dst="$MNT/etc/NetworkManager/system-connections/$(basename "$f")"
		# drop the interface binding: the interface name differs in the new system
		grep -v '^interface-name=' "$f" >"$dst"
		chmod 600 "$dst"
		chown 0:0 "$dst"
		n=$((n + 1))
		echo "    $(basename "$f")"
	done
	[ "$n" -gt 0 ] || echo "    no Wi-Fi profile found (the new system will need Wi-Fi set up by hand)"
fi

# --------------------------------------------------------------- boot loader
say "boot loader and initramfs"
mount -t proc proc "$MNT/proc"
mount --rbind /sys "$MNT/sys"
mount --make-rslave "$MNT/sys"
mount --rbind /dev "$MNT/dev"
mount --make-rslave "$MNT/dev"
mount --bind /run "$MNT/run"
if [ -n "$PASS" ]; then
	printf '%s:%s\n' "$IMG_USER" "$PASS" | chroot "$MNT" /usr/sbin/chpasswd ||
		die "could not set the password of $IMG_USER"
	unset PASS
	echo "    password of $IMG_USER set"
fi
# every installation gets its own SSH host keys and machine id (the image
# carries none); the keys are named after the new system's host name
chroot "$MNT" /usr/bin/unshare --uts /bin/sh -c 'hostname "$(cat /etc/hostname)";
	rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub &&
	/usr/bin/ssh-keygen -A >/dev/null' || die "could not create SSH host keys"
: >"$MNT/etc/machine-id"
rm -f "$MNT/var/lib/dbus/machine-id"
echo "    new SSH host keys created"
nvram_opt=""
if [ ! -d /sys/firmware/efi/efivars ] || [ -z "$(ls -A /sys/firmware/efi/efivars 2>/dev/null)" ]; then
	echo "    EFI variables not available: installing to the fallback boot path only"
	nvram_opt="--no-nvram"
fi
# shellcheck disable=SC2086
chroot "$MNT" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin \
	grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian \
	--recheck --force-extra-removable $nvram_opt
chroot "$MNT" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin update-initramfs -u -k all
chroot "$MNT" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin update-grub
ls -la "$MNT/boot/efi/EFI" "$MNT/boot/efi/EFI/BOOT" 2>/dev/null || true

say "finishing"
sync
umount -R "$MNT/run" "$MNT/dev" "$MNT/sys" "$MNT/proc" 2>/dev/null || true
umount "$MNT/boot/efi"
umount "$MNT"
sync
cat <<EOF

==========================================================
 Installation finished.
 1. Power off or reboot:   reboot
 2. Remove the USB stick when the screen goes dark.
 The tablet then starts Debian and logs in automatically.
==========================================================
EOF
