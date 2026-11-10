#!/bin/bash
# gbook-diag.sh — read-only hardware report for the Samsung Galaxy Book 10.6.
# Run as root in a live or installed Linux system. Nothing is modified on the
# machine; the report is written to a tar.gz in the current directory (or $1).
#
#   sudo ./gbook-diag.sh [output-directory]
set -u

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

OUTDIR=${1:-$PWD}
STAMP=$(date +%Y%m%d-%H%M%S)
WORK=$(mktemp -d)
D="$WORK/gbook-diag-$STAMP"
mkdir -p "$D"

run() { # run <file> <command...>
	local f=$1; shift
	{ echo "\$ $*"; "$@" 2>&1; } >"$D/$f" || true
}
have() { command -v "$1" >/dev/null 2>&1; }
catall() { # catall <file> <glob...>  (prints "path: content" for small sysfs files)
	local f=$1 p; shift
	for p in "$@"; do
		[ -f "$p" ] && [ -r "$p" ] && printf '%s: %s\n' "$p" "$(head -c 400 "$p" 2>/dev/null | tr '\n' ' ')"
	done >"$D/$f" 2>/dev/null
}

# identity
run uname.txt uname -a
catall dmi.txt /sys/class/dmi/id/*
run os-release.txt cat /etc/os-release
run cmdline.txt cat /proc/cmdline
run cpuinfo.txt cat /proc/cpuinfo
run meminfo.txt cat /proc/meminfo
run dmesg.txt dmesg
have lspci && run lspci.txt lspci -nnk
have lsusb && run lsusb.txt lsusb
have lsusb && run lsusb-v.txt lsusb -v
run lsmod.txt lsmod
have lsblk && run lsblk.txt lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINT,MODEL
have efibootmgr && run efibootmgr.txt efibootmgr -v
if have mokutil; then run secureboot.txt mokutil --sb-state; else catall secureboot.txt /sys/firmware/efi/efivars/SecureBoot-*; fi

# ACPI: raw tables (for mount matrix, device status) and the device list
mkdir -p "$D/acpi-tables"
cp /sys/firmware/acpi/tables/[A-Z]* "$D/acpi-tables/" 2>/dev/null
[ -d /sys/firmware/acpi/tables/dynamic ] && cp -r /sys/firmware/acpi/tables/dynamic "$D/acpi-tables/" 2>/dev/null
for a in /sys/bus/acpi/devices/*; do
	printf '%s hid=%s status=%s path=%s driver=%s\n' "$(basename "$a")" \
		"$(cat "$a/hid" 2>/dev/null)" "$(cat "$a/status" 2>/dev/null)" "$(cat "$a/path" 2>/dev/null)" \
		"$(basename "$(readlink "$a/physical_node/driver" 2>/dev/null)" 2>/dev/null)"
done >"$D/acpi-devices.txt" 2>/dev/null

# buses and sensors
for i in /sys/bus/i2c/devices/*; do
	printf '%s name=%s modalias=%s driver=%s\n' "$(basename "$i")" "$(cat "$i/name" 2>/dev/null)" \
		"$(cat "$i/modalias" 2>/dev/null)" "$(basename "$(readlink "$i/driver" 2>/dev/null)" 2>/dev/null)"
done >"$D/i2c-devices.txt" 2>/dev/null
for i in /sys/bus/iio/devices/iio:device*; do
	[ -d "$i" ] || continue
	echo "== $i name=$(cat "$i/name" 2>/dev/null)"
	for f in "$i"/in_*_raw "$i"/in_*_scale "$i"/*mount_matrix "$i"/in_illuminance*; do
		[ -f "$f" ] && printf '   %s = %s\n' "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
	done
done >"$D/iio.txt" 2>/dev/null
have udevadm && for i in /sys/bus/iio/devices/iio:device*; do [ -d "$i" ] && udevadm info "$i"; done >"$D/iio-udev.txt" 2>&1

# input: touchscreen, pen, keyboard cover, buttons, tablet-mode switch
run input-devices.txt cat /proc/bus/input/devices
have libinput && run libinput-list.txt libinput list-devices
have udevadm && for e in /dev/input/event*; do echo "== $e"; udevadm info "$e" | grep -E 'ID_INPUT|NAME|ID_PATH=|LIBINPUT|WL_OUTPUT'; done >"$D/input-udev.txt" 2>&1

# display
for c in /sys/class/drm/card*-*; do
	echo "== $c status=$(cat "$c/status" 2>/dev/null) enabled=$(cat "$c/enabled" 2>/dev/null)"
	echo "   modes: $(tr '\n' ' ' <"$c/modes" 2>/dev/null)"
	[ -s "$c/edid" ] && cp "$c/edid" "$D/edid-$(basename "$c").bin" 2>/dev/null
done >"$D/drm.txt" 2>/dev/null
have drm_info && run drm_info.txt drm_info
catall fb.txt /sys/class/graphics/fb0/virtual_size /sys/class/graphics/fb0/rotate /sys/class/graphics/fbcon/rotate
catall backlight.txt /sys/class/backlight/*/type /sys/class/backlight/*/max_brightness /sys/class/backlight/*/brightness

# audio
run asound-cards.txt cat /proc/asound/cards
for c in /proc/asound/card*/codec#*; do [ -f "$c" ] && cp "$c" "$D/$(echo "$c" | tr '/#' '__' | sed 's/^_proc_//').txt"; done 2>/dev/null
have aplay && run aplay-l.txt aplay -l
have wpctl && run wpctl-status.txt wpctl status

# power, thermal, radios, storage
catall power-supply.txt /sys/class/power_supply/*/uevent
catall thermal.txt /sys/class/thermal/thermal_zone*/type /sys/class/thermal/thermal_zone*/temp
catall sleep.txt /sys/power/state /sys/power/mem_sleep
have rfkill && run rfkill.txt rfkill list
have ip && run ip-addr.txt ip -brief addr
have iw && run iw-dev.txt iw dev
catall mmc.txt /sys/block/mmcblk*/device/name /sys/block/mmcblk*/device/manfid /sys/block/mmcblk*/device/life_time /sys/block/mmcblk*/size

mkdir -p "$OUTDIR"
OUT="$OUTDIR/gbook-diag-$STAMP.tar.gz"
tar -C "$WORK" -czf "$OUT" "gbook-diag-$STAMP"
rm -rf "$WORK"
echo "report: $OUT"
