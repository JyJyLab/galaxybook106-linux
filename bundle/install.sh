#!/bin/bash
# Galaxy Book 10.6 (SM-W620/W627) support bundle installer for Debian/Ubuntu.
#
#   sudo ./install.sh [--user NAME] [--force] <component>...
#
# components:
#   accel    accelerometer glue module (DKMS) + provisional mount matrix
#   audio    speaker / headphone jack initialisation (ALC298 144d:c150)
#   desktop  rotation helpers + labwc config for the Xfce Wayland session
#   greetd   automatic login into the Xfce Wayland session
#   cover    keyboard cover touchpad helper (experimental, not in "all"; see cover/)
#   power    sleep on power button and cover close (logind), charger no wake source
#   camera   front camera: IMX241 kernel modules (DKMS), libcamera with IMX241,
#            ImgU IOMMU fix, PipeWire and Firefox settings
#   all      accel audio desktop greetd power camera
#
# --user NAME  desktop user (default: $SUDO_USER)
# --force      skip the DMI model check (for build tests on other machines)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TARGET_USER=${SUDO_USER:-}
FORCE=0
COMPONENTS=()

while [ $# -gt 0 ]; do
	case "$1" in
	--user) TARGET_USER=${2:?--user needs a name}; shift 2 ;;
	--force) FORCE=1; shift ;;
	-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
	all) COMPONENTS+=(accel audio desktop greetd power camera); shift ;;
	accel|audio|desktop|greetd|cover|power|camera) COMPONENTS+=("$1"); shift ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
[ ${#COMPONENTS[@]} -gt 0 ] || { sed -n '2,20p' "$0"; exit 2; }

say() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
booted() { [ -d /run/systemd/system ]; }

check_model() {
	local vendor product
	vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
	product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
	case "$product" in
	"Galaxy Book 10.6"*) return 0 ;;	# Wi-Fi model, or "Galaxy Book 10.6 LTE"
	esac
	if [ "$FORCE" = 1 ]; then
		warn "not a Galaxy Book 10.6 ('$vendor' / '$product'), continuing because of --force"
		return 0
	fi
	echo "This machine is '$vendor' / '$product', not a Samsung Galaxy Book 10.6." >&2
	echo "Use --force only for build tests." >&2
	exit 1
}

need_user() {
	[ -n "$TARGET_USER" ] || { echo "no desktop user: pass --user NAME" >&2; exit 2; }
	getent passwd "$TARGET_USER" >/dev/null || { echo "user '$TARGET_USER' does not exist" >&2; exit 2; }
	USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
	USER_GROUP=$(id -gn "$TARGET_USER")
}

apt_install() {
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

backup_file() {
	local f=$1
	if [ -e "$f" ] && [ ! -e "$f.gbook-orig" ]; then
		cp -a "$f" "$f.gbook-orig"
	fi
}

install_accel() {
	say "accelerometer glue module (DKMS)"
	local name=gbook-accel ver=1.0
	apt_install dkms
	# headers for the installed kernel(s); the meta package keeps them in step
	apt_install linux-headers-amd64 || warn "linux-headers-amd64 not installable, install headers manually"
	if dkms status -m "$name" -v "$ver" 2>/dev/null | grep -q .; then
		dkms remove -m "$name" -v "$ver" --all || true
	fi
	rm -rf "/usr/src/$name-$ver"
	cp -r "$HERE/accel-dkms/$name-$ver" "/usr/src/$name-$ver"
	dkms add -m "$name" -v "$ver"
	local built=0 k
	for k in /lib/modules/*; do
		[ -d "$k/build" ] || continue
		if dkms install -m "$name" -v "$ver" -k "$(basename "$k")"; then
			built=1
		else
			warn "module build failed for $(basename "$k")"
		fi
	done
	[ "$built" = 1 ] || warn "module was not built for any kernel (no headers?)"
	install -D -m 644 "$HERE/accel-dkms/61-sensor-galaxybook106.hwdb" /etc/udev/hwdb.d/61-sensor-galaxybook106.hwdb
	systemd-hwdb update || true
	if booted; then
		modprobe st_accel_sam0201 || warn "modprobe st_accel_sam0201 failed (see dmesg)"
		udevadm trigger --subsystem-match=iio || true
		local n
		for n in /sys/bus/iio/devices/iio:device*/name; do
			[ -e "$n" ] && echo "    iio: $(dirname "$n") -> $(cat "$n")"
		done
	fi
}

install_audio() {
	say "audio initialisation (ALC298 144d:c150)"
	local up="$HERE/audio/upstream"
	apt_install alsa-tools python3
	install -d -m 755 /usr/local/lib/galaxybook-audio /usr/local/bin /etc/systemd/system-sleep
	install -m 755 "$up/scripts/initializeALC298.py" "$up/scripts/setHeadphone.py" "$up/scripts/amp_replay.py" /usr/local/lib/galaxybook-audio/
	install -m 644 "$up/scripts/verbUI.py" "$up/scripts/amp_ops.json" /usr/local/lib/galaxybook-audio/
	install -m 755 "$up/bin/galaxybook-audio-init" "$up/bin/galaxybook-jack-watch" /usr/local/bin/
	install -m 755 "$HERE/audio/gbook-audio-check" /usr/local/bin/gbook-audio-check
	install -m 644 "$up/systemd/galaxybook-audio.service" "$up/systemd/galaxybook-jack-watch.service" /etc/systemd/system/
	install -m 755 "$HERE/audio/galaxybook-audio.sleep" /etc/systemd/system-sleep/galaxybook-audio
	local unit
	for unit in galaxybook-audio.service galaxybook-jack-watch.service; do
		install -d -m 755 "/etc/systemd/system/$unit.d"
		printf '[Service]\nExecCondition=/usr/local/bin/gbook-audio-check\n' >"/etc/systemd/system/$unit.d/10-gbook-guard.conf"
	done
	# keep the ALSA node awake (system-wide instead of the upstream per-user file)
	install -D -m 644 "$up/wireplumber/51-alc298-no-suspend.conf" /etc/wireplumber/wireplumber.conf.d/51-alc298-no-suspend.conf
	if booted; then
		systemctl daemon-reload
		systemctl enable --now galaxybook-audio.service galaxybook-jack-watch.service || warn "could not start audio services"
	else
		systemctl enable galaxybook-audio.service galaxybook-jack-watch.service
	fi
}

install_desktop() {
	say "rotation helpers and labwc configuration"
	need_user
	apt_install labwc wlr-randr iio-sensor-proxy brightnessctl libnotify-bin
	# gbook-touch-calibrate (GTK 3 through Python), gbook-osk-auto (GLib/D-Bus),
	# on-screen keyboard
	apt_install python3-gi gir1.2-gtk-3.0 wvkbd
	# volume and battery items of the panel (gbook-panel-setup skips missing ones)
	apt_install xfce4-pulseaudio-plugin xfce4-power-manager-plugins ||
		warn "panel plugins for volume/battery not installable"
	install -m 755 "$HERE/desktop/bin/gbook-display" "$HERE/desktop/bin/gbook-autorotate" \
		"$HERE/desktop/bin/gbook-session" "$HERE/desktop/bin/gbook-osk" \
		"$HERE/desktop/bin/gbook-panel-setup" "$HERE/desktop/bin/gbook-osd" \
		"$HERE/desktop/bin/gbook-touch-calibrate" "$HERE/desktop/bin/gbook-osk-auto" \
		/usr/local/bin/
	# on-screen keyboard with Korean labels and a Hangul/English key (osk/README)
	if [ "$(dpkg --print-architecture)" = amd64 ] && [ -f "$HERE/osk/wvkbd-gbook" ]; then
		install -m 755 "$HERE/osk/wvkbd-gbook" /usr/local/bin/wvkbd-gbook
	fi
	# first login of each user: tablet items on the Xfce panel
	install -D -m 644 "$HERE/desktop/autostart/gbook-panel-setup.desktop" \
		/etc/xdg/autostart/gbook-panel-setup.desktop
	if [ ! -e /etc/gbook/display.conf ]; then
		install -D -m 644 "$HERE/desktop/etc/display.conf" /etc/gbook/display.conf
	else
		echo "    keeping existing /etc/gbook/display.conf"
	fi
	install -d -m 755 /usr/local/share/applications
	install -m 644 "$HERE"/desktop/applications/*.desktop /usr/local/share/applications/
	local cfg="$USER_HOME/.config/xfce4/labwc" f
	install -d -o "$TARGET_USER" -g "$USER_GROUP" "$USER_HOME/.config" "$USER_HOME/.config/xfce4" "$cfg"
	for f in rc.xml environment autostart; do
		backup_file "$cfg/$f"
		install -m 644 -o "$TARGET_USER" -g "$USER_GROUP" "$HERE/desktop/labwc/$f" "$cfg/$f"
	done
	# stop startxfce4 from rewriting the keyboard layout in "environment"
	install -m 644 -o "$TARGET_USER" -g "$USER_GROUP" /dev/null "$cfg/lock"
	# backlight control for brightnessctl (members of the video group)
	usermod -aG video "$TARGET_USER"
	cat >/etc/udev/rules.d/90-gbook-backlight.rules <<'EOR'
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
EOR
	# the touchscreen calibration lives in the labwc configuration only
	# (gbook-touch-calibrate edits it); drop the udev default of older installs
	rm -f /etc/udev/rules.d/90-gbook-touch.rules
}

install_greetd() {
	say "automatic login (greetd)"
	need_user
	apt_install greetd
	backup_file /etc/greetd/config.toml
	cat >/etc/greetd/config.toml <<EOF
[terminal]
vt = 7

# Text login shown after logging out of the automatic session.
[default_session]
command = "/usr/sbin/agreety --cmd /usr/local/bin/gbook-session"
user = "_greetd"

# Started once at boot without asking for a password.
[initial_session]
command = "/usr/local/bin/gbook-session"
user = "$TARGET_USER"
EOF
	[ -x /usr/local/bin/gbook-session ] || warn "gbook-session missing: install the desktop component too"
	systemctl enable greetd.service
	systemctl set-default graphical.target >/dev/null 2>&1 || true
	local dm
	for dm in lightdm gdm3 sddm; do
		if systemctl is-enabled "$dm.service" >/dev/null 2>&1; then
			warn "$dm is enabled as well; disable it (systemctl disable $dm) so that greetd owns the display"
		fi
	done
}

install_cover() {
	say "keyboard cover touchpad helper"
	apt_install python3
	install -D -m 755 "$HERE/cover/gbook-touchpad-wake" /usr/local/sbin/gbook-touchpad-wake
	install -D -m 644 "$HERE/cover/gbook-touchpad-wake.service" /etc/systemd/system/gbook-touchpad-wake.service
	install -D -m 644 "$HERE/cover/90-gbook-cover.rules" /etc/udev/rules.d/90-gbook-cover.rules
	if [ -d /run/systemd/system ]; then
		systemctl daemon-reload
		udevadm control --reload || true
	fi
}

install_power() {
	say "sleep on power button and cover close"
	need_user
	install -D -m 644 "$HERE/power/10-gbook.conf" /etc/systemd/logind.conf.d/10-gbook.conf
	install -D -m 644 "$HERE/power/90-gbook-power.rules" /etc/udev/rules.d/90-gbook-power.rules
	install -m 755 "$HERE/power/gbook-power-setup" /usr/local/bin/gbook-power-setup
	# xfce4-power-manager must leave the power button and the cover to logind
	# (gbook-power-setup explains why). New account: settings file; running
	# session: set the values through xfconf.
	local xf="$USER_HOME/.config/xfce4/xfconf/xfce-perchannel-xml" uid bus
	uid=$(id -u "$TARGET_USER")
	bus="/run/user/$uid/bus"
	if [ -S "$bus" ] && command -v runuser >/dev/null 2>&1 &&
		runuser -u "$TARGET_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
			DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" /usr/local/bin/gbook-power-setup; then
		echo "    power manager settings applied to the running session"
	elif [ ! -e "$xf/xfce4-power-manager.xml" ]; then
		install -d -o "$TARGET_USER" -g "$USER_GROUP" "$USER_HOME/.config" "$USER_HOME/.config/xfce4" \
			"$USER_HOME/.config/xfce4/xfconf" "$xf"
		install -m 644 -o "$TARGET_USER" -g "$USER_GROUP" "$HERE/power/xfce4-power-manager.xml" \
			"$xf/xfce4-power-manager.xml"
	else
		warn "run gbook-power-setup as $TARGET_USER inside the Xfce session"
	fi
	if [ -d /run/systemd/system ]; then
		udevadm control --reload || true
		udevadm trigger --action=change --subsystem-match=power_supply || true
		systemctl kill -s HUP systemd-logind 2>/dev/null || true
	fi
}

install_camera() {
	say "front camera (Sony IMX241)"
	local name=gbook-camera ver=0.1 k built=0
	apt_install dkms
	apt_install linux-headers-amd64 || warn "linux-headers-amd64 not installable, install headers manually"
	# 1. kernel side: int3472 supply types, ipu-bridge entry, imx241 driver
	if dkms status -m "$name" -v "$ver" 2>/dev/null | grep -q .; then
		dkms remove -m "$name" -v "$ver" --all || true
	fi
	rm -rf "/usr/src/$name-$ver"
	cp -r "$HERE/camera/$name-$ver" "/usr/src/$name-$ver"
	dkms add -m "$name" -v "$ver"
	for k in /lib/modules/*; do
		[ -d "$k/build" ] || continue
		case "$(basename "$k")" in
		7.2.*) ;;
		*) warn "camera modules are for 7.2 kernels only, skipping $(basename "$k")"; continue ;;
		esac
		if dkms install -m "$name" -v "$ver" -k "$(basename "$k")"; then
			built=1
		else
			warn "camera module build failed for $(basename "$k")"
		fi
	done
	[ "$built" = 1 ] || warn "camera modules were not built for any kernel"
	# 2. the IPU3 imaging unit must not sit behind IOMMU translation (machine hang)
	install -D -m 755 "$HERE/camera/gbook-imgu-identity" /usr/local/sbin/gbook-imgu-identity
	install -D -m 644 "$HERE/camera/gbook-imgu.conf" /etc/modprobe.d/gbook-imgu.conf
	# 3. libcamera 0.7.2 with the IMX241 sensor helper (local build, held)
	if [ "$(dpkg --print-architecture)" = amd64 ]; then
		DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --allow-downgrades --allow-change-held-packages \
			"$HERE"/camera/debs/*.deb || warn "libcamera packages could not be installed"
		apt-mark hold libcamera0.7 libcamera-ipa libcamera-tools libcamera-v4l2 gstreamer1.0-libcamera >/dev/null || true
	fi
	apt_install libspa-0.2-libcamera
	# 4. PipeWire shows only the libcamera camera; Firefox may use it
	install -D -m 644 "$HERE/camera/60-gbook-camera.conf" /etc/wireplumber/wireplumber.conf.d/60-gbook-camera.conf
	if [ -f /etc/firefox-esr/firefox-esr.js ] && ! grep -q "camera.allow-pipewire" /etc/firefox-esr/firefox-esr.js; then
		{ echo; cat "$HERE/camera/gbook-camera-firefox.js"; } >>/etc/firefox-esr/firefox-esr.js
	fi
	booted && echo "    reboot to load the camera modules"
	return 0
}

check_model
for c in "${COMPONENTS[@]}"; do
	"install_$c"
done
say "done: ${COMPONENTS[*]}"
