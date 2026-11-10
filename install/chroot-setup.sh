#!/bin/bash
# chroot-setup.sh — configure a Debian forky root filesystem for the Samsung
# Galaxy Book 10.6. Runs INSIDE the target root (chroot) as root.
#
# Expects next to this script:  pkglist.txt, bundle/, authorized_keys (optional)
# Environment:  GB_USER (default gbook), GB_HOSTNAME (default gbook),
#               GB_PUBLIC=1 (default) public image: no SSH key, SSH server off,
#               sudo asks for the password (set by the installer);
#               GB_PUBLIC=0 personal image: SSH key login, sudo without password
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GB_USER=${GB_USER:-gbook}
GB_HOSTNAME=${GB_HOSTNAME:-gbook}
GB_PUBLIC=${GB_PUBLIC:-1}
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8

say() { echo "==> $*"; }

say "apt sources (forky: main contrib non-free non-free-firmware)"
rm -f /etc/apt/sources.list
cat >/etc/apt/sources.list.d/debian.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: forky forky-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: forky-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp
EOF
cat >/etc/apt/apt.conf.d/90gbook <<'EOF'
APT::Install-Recommends "false";
EOF

# no service starts while building the image
printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

say "base upgrade"
apt-get update
apt-get -y dist-upgrade

say "debconf preseed (locale, time zone, keyboard)"
apt-get -y install debconf-utils locales tzdata
debconf-set-selections <<'EOF'
locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8, ko_KR.UTF-8 UTF-8
locales locales/default_environment_locale select ko_KR.UTF-8
tzdata tzdata/Areas select Asia
tzdata tzdata/Zones/Asia select Seoul
keyboard-configuration keyboard-configuration/layoutcode string kr
keyboard-configuration keyboard-configuration/variantcode string kr104
keyboard-configuration keyboard-configuration/modelcode string pc105
EOF
sed -i -e 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' -e 's/^# *\(ko_KR.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
update-locale LANG=ko_KR.UTF-8
ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime
echo "Asia/Seoul" >/etc/timezone
dpkg-reconfigure -f noninteractive tzdata

say "packages"
mapfile -t PKGS < <(grep -v '^#' "$HERE/pkglist.txt" | tr ' ' '\n' | sed '/^$/d')
apt-get -y install "${PKGS[@]}"

say "host name"
echo "$GB_HOSTNAME" >/etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1	localhost
127.0.1.1	$GB_HOSTNAME

::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

say "console keyboard"
cat >/etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="kr"
XKBVARIANT="kr104"
XKBOPTIONS=""
BACKSPACE="guess"
EOF

say "user $GB_USER"
if ! getent passwd "$GB_USER" >/dev/null; then
	useradd -m -s /bin/bash -c "$GB_USER" "$GB_USER"
fi
for g in sudo video audio input plugdev netdev bluetooth render; do
	getent group "$g" >/dev/null && usermod -aG "$g" "$GB_USER"
done
passwd -l "$GB_USER" >/dev/null
UHOME=$(getent passwd "$GB_USER" | cut -d: -f6)
install -d -m 700 -o "$GB_USER" -g "$GB_USER" "$UHOME/.ssh"
if [ -s "$HERE/authorized_keys" ]; then
	install -m 600 -o "$GB_USER" -g "$GB_USER" "$HERE/authorized_keys" "$UHOME/.ssh/authorized_keys"
fi
if [ "$GB_PUBLIC" = 1 ]; then
	# public image: sudo with the password chosen during installation
	rm -f /etc/sudoers.d/90-gbook-user
else
	printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$GB_USER" >/etc/sudoers.d/90-gbook-user
	chmod 440 /etc/sudoers.d/90-gbook-user
	visudo -cf /etc/sudoers.d/90-gbook-user
fi
install -d /etc/gbook
printf 'GB_USER=%s\nGB_PUBLIC=%s\nBUILD_DATE=%s\n' "$GB_USER" "$GB_PUBLIC" "$(date +%F)" >/etc/gbook/build-info

say "Korean input (fcitx5 + hangul)"
install -d -o "$GB_USER" -g "$GB_USER" "$UHOME/.config" "$UHOME/.config/fcitx5"
cat >"$UHOME/.config/fcitx5/profile" <<'EOF'
[Groups/0]
Name=Default
Default Layout=kr-kr104
DefaultIM=hangul

[Groups/0/Items/0]
Name=keyboard-kr-kr104
Layout=

[Groups/0/Items/1]
Name=hangul
Layout=

[GroupOrder]
0=Default
EOF
chown "$GB_USER:$GB_USER" "$UHOME/.config/fcitx5/profile"

say "support bundle (accelerometer, audio, rotation, automatic login)"
"$HERE/bundle/install.sh" --force --user "$GB_USER" all

say "memory compression, storage trim, boot loader defaults"
cat >/etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
systemctl enable zramswap.service fstrim.timer NetworkManager.service bluetooth.service thermald.service >/dev/null 2>&1 || true
if [ "$GB_PUBLIC" = 1 ]; then
	# no remote login on a public image unless the owner turns it on
	systemctl disable ssh.service ssh.socket >/dev/null 2>&1 || true
else
	systemctl enable ssh.service >/dev/null 2>&1 || true
fi
# The kernel's panel orientation quirk only matches the product name
# "Galaxy Book 10.6"; the LTE model reports "Galaxy Book 10.6 LTE", so the
# orientation of the portrait-native panel is given on the command line
# (left side up on the SM-W627, confirmed on the device).
sed -i -e 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' \
	-e 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="quiet video=eDP-1:panel_orientation=left_side_up"|' /etc/default/grub
install -d /etc/systemd/journald.conf.d /etc/systemd/logind.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' >/etc/systemd/journald.conf.d/10-gbook.conf
# apt starts apt-daily.service on every "charger connected" event
# (/usr/lib/udev/rules.d/61-apt.rules). With a charger that drops out every few
# seconds this ran the apt job every 10-20 s on the device (80 runs in 30
# minutes, 1.4 s of CPU each). The daily timers stay active.
ln -sfn /dev/null /etc/udev/rules.d/61-apt.rules

# power button / cover sleep settings: bundle component "power" (install.sh all)

# placeholder; the real file is written when the image is put on the tablet
cat >/etc/fstab <<'EOF'
# /etc/fstab — written during installation on the tablet
EOF

say "cleanup"
rm -f /usr/sbin/policy-rc.d
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
: >/etc/machine-id
rm -f /var/lib/dbus/machine-id
# SSH host keys are made per installation by gbook-install (the ones created
# here would be shared by every installed tablet and name the build host)
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

say "summary"
echo "packages: $(dpkg -l | grep -c '^ii')"
echo "kernel:   $(ls /lib/modules)"
dkms status || true
echo "user:     $(id "$GB_USER")"
