#!/bin/bash
# gbook-live.sh — autorun helper on the Galaxy Book 10.6 live USB (SystemRescue).
# Makes the installer tools available, helps to join a Wi-Fi network with a
# minimum of typing and shows the address for remote (SSH) access.
# Console text is ASCII only: the Linux text console cannot display Korean.

MEDIA=/run/archiso/bootmnt

line() { printf '%s\n' "------------------------------------------------------------"; }

# installer tools from the boot medium
for f in gbook-install.sh gbook-diag.sh; do
	if [ -f "$MEDIA/gbook/$f" ]; then
		install -m 755 "$MEDIA/gbook/$f" "/usr/local/bin/${f%.sh}"
	fi
done

systemctl start sshd >/dev/null 2>&1

online() {
	ip -4 route get 1.1.1.1 >/dev/null 2>&1
}

ip4_list() {
	ip -4 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $2 ": " $4}'
}

wifi_dev() {
	nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2 == "wifi" {print $1; exit}'
}

scan_list() {
	# prints "signal<TAB>security<TAB>ssid", strongest first, one line per SSID
	nmcli -t -f SIGNAL,SECURITY,SSID device wifi list --rescan yes 2>/dev/null |
		awk '{
			i = index($0, ":"); sig = substr($0, 1, i - 1); rest = substr($0, i + 1)
			j = index(rest, ":"); sec = substr(rest, 1, j - 1); ssid = substr(rest, j + 1)
			gsub(/\\:/, ":", ssid); gsub(/\\\\/, "\\", ssid)
			if (ssid == "" || seen[ssid]++) next
			if (sec == "") sec = "open"
			print sig "\t" sec "\t" ssid
		}' | sort -t "$(printf '\t')" -k1,1nr | head -n 12
}

connect_wifi() {
	local dev choice ssid sec pw n
	dev=$(wifi_dev)
	if [ -z "$dev" ]; then
		echo "No Wi-Fi adapter found."
		return 1
	fi
	while :; do
		echo
		echo "Scanning for Wi-Fi networks..."
		mapfile -t NETS < <(scan_list)
		if [ "${#NETS[@]}" -eq 0 ]; then
			echo "No network found."
		fi
		n=1
		for entry in "${NETS[@]}"; do
			IFS=$'\t' read -r sig sec ssid <<<"$entry"
			printf '  %2d) %-32s %3s%%  %s\n' "$n" "$ssid" "$sig" "$sec"
			n=$((n + 1))
		done
		echo
		read -r -p "Number of your Wi-Fi (r = scan again, m = type name, q = skip): " choice
		case "$choice" in
		q|Q) return 1 ;;
		r|R|"") continue ;;
		m|M)
			read -r -p "Wi-Fi name (SSID): " ssid
			sec="WPA" ;;
		*[!0-9]*) echo "Please type a number."; continue ;;
		*)
			if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#NETS[@]}" ]; then
				echo "No such number."
				continue
			fi
			IFS=$'\t' read -r sig sec ssid <<<"${NETS[$((choice - 1))]}" ;;
		esac
		[ -n "$ssid" ] || continue
		if [ "$sec" = "open" ]; then
			nmcli device wifi connect "$ssid" ifname "$dev" && return 0
		else
			read -r -p "Password for '$ssid' (shown while typing): " pw
			nmcli device wifi connect "$ssid" password "$pw" ifname "$dev" && return 0
		fi
		echo "Could not connect. Try again."
	done
}

show_status() {
	echo
	line
	echo " Galaxy Book 10.6 - Linux installer (live system)"
	line
	# remote installation only when an SSH key was put on the stick
	if online && [ -s /root/.ssh/authorized_keys ]; then
		echo " NETWORK OK.  Address of this tablet:"
		ip4_list | sed 's/^/     /'
		echo
		echo " Remote installation can start now. Leave the tablet switched on."
		echo
		echo " Local installation:   gbook-install"
	elif online; then
		echo " NETWORK OK.  The Wi-Fi profile will be copied to the new system."
		echo
		echo " Start the installation:   gbook-install"
	else
		echo " NO NETWORK.  Run   gbook-live   to set up Wi-Fi (optional)."
		echo
		echo " Start the installation:   gbook-install"
	fi
	line
	echo
}

if [ "${1:-}" = "--status" ]; then
	show_status
	exit 0
fi

clear 2>/dev/null
line
echo " Galaxy Book 10.6 - Linux installer (live system)"
line

# wait a little for an already working connection (USB Ethernet, saved profile)
for _ in $(seq 1 15); do
	online && break
	sleep 1
done

if ! online; then
	connect_wifi
	for _ in $(seq 1 10); do
		online && break
		sleep 1
	done
fi

show_status

# keep the helper available, and show the status again after the console
# login (the login banner clears the screen)
if [ "$(readlink -f "$0")" != /usr/local/bin/gbook-live ]; then
	install -m 755 "$0" /usr/local/bin/gbook-live 2>/dev/null
fi
cat >/etc/profile.d/zz-gbook-status.sh <<'EOF'
# show the installer status on interactive console logins
case "$(tty 2>/dev/null)" in
/dev/tty[0-9]*) [ -x /usr/local/bin/gbook-live ] && /usr/local/bin/gbook-live --status ;;
esac
EOF
exit 0
