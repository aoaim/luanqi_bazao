#!/usr/bin/env bash

# TCSCloud HiNet Dynamic IP Switch Script

# Crontab example (Beijing time, every Sunday 04:20):
# CRON_TZ=Asia/Shanghai
# 20 4 * * 0 /bin/bash /path/to/changeip.sh >> /var/log/changeip.log 2>&1

set -u

HOST="ipapi.tcscloud.net"
PORT="8002"
GET_PATH="/getip"
CHANGE_PATH="/changeip"
DNS_SERVERS=("100.100.101.101" "100.100.101.102")
TIMEOUT_SECONDS=10

resolve_host_ip() {
	local dns ip
	for dns in "${DNS_SERVERS[@]}"; do
		ip=$(nslookup "$HOST" "$dns" 2>/dev/null | awk '/^Address: / {print $2}' | tail -n1)
		if [[ -n "$ip" ]]; then
			printf '%s' "$ip"
			return 0
		fi
	done
	return 1
}

api_call() {
	local path="$1"
	local resolved_ip="$2"
	curl -fsS --max-time 10 --resolve "${HOST}:${PORT}:${resolved_ip}" "http://${HOST}:${PORT}${path}"
}

change_ip() {
	local resolved_ip="$1"
	local new_ip
	if new_ip=$(api_call "$CHANGE_PATH" "$resolved_ip"); then
		echo "result: ${new_ip}"
	else
		echo "error: changeip failed" >&2
		return 1
	fi
}

main() {
	local resolved_ip current_ip answer

	if ! resolved_ip=$(resolve_host_ip); then
		echo "error: failed to resolve ${HOST} via dedicated DNS servers: ${DNS_SERVERS[*]}" >&2
		exit 1
	fi

	echo "resolved: ${HOST} -> ${resolved_ip}"

	if current_ip=$(api_call "$GET_PATH" "$resolved_ip"); then
		echo "ip: ${current_ip}"
	else
		echo "error: failed to get current ip" >&2
		exit 1
	fi

	if [[ ! -t 0 ]]; then
		echo "non-interactive input detected, auto changing ip now"
		change_ip "$resolved_ip"
		exit $?
	fi

	echo "change ip? (yes/y to change, no/n to keep, auto-confirm in ${TIMEOUT_SECONDS}s)"
	if read -r -t "$TIMEOUT_SECONDS" -p "> " answer; then
		answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
		case "$answer" in
			yes|y)
				change_ip "$resolved_ip"
				;;
			no|n)
				echo "unchanged"
				;;
			*)
				echo "invalid input, unchanged"
				;;
		esac
	else
		echo
		echo "no input within ${TIMEOUT_SECONDS}s, auto changing ip now"
		change_ip "$resolved_ip"
	fi
}

main
