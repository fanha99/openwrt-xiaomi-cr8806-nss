#!/bin/sh
# Walk-test sampler. Every 2 s logs the signal of every connected station per BSS;
# every 10 s also logs usteer's roam counters. Writes to /tmp (RAM, no flash wear).
# MACs are shortened to the last 5 hex digits. Stop with: kill $(cat /tmp/roamlog.pid)
L=${L:-/tmp/roamlog.log}
echo "# start $(date +%F_%T) $(cat /proc/sys/kernel/hostname)" >> "$L"
i=0
while :; do
	t=$(date +%H:%M:%S)
	for b in w-lan w-guest w-iot; do
		iw dev "$b" station dump 2>/dev/null | awk -v t="$t" -v b="$b" '
			/^Station/ { m = substr($2, length($2) - 4) }
			/signal:/ && m { printf "%s %s %s %s\n", t, b, m, $2; m = "" }'
	done >> "$L"
	i=$((i + 1))
	if [ $((i % 5)) = 0 ]; then
		printf '%s roam %s\n' "$t" \
			"$(ubus call usteer local_info | tr -d ' \n' | sed 's/"hostapd\./ /g; s/":{"bssid[^}]*"roam_events":{"source":/=/g; s/,"target":/\//g; s/}}*//g')" >> "$L"
	fi
	sleep 2
done
