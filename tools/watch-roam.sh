#!/bin/sh
# Walk test watcher: every $IV seconds show which AP each Wi-Fi client sits on and
# what signal each AP hears for it, plus usteer's roam counters. Parsing happens
# here, not on the router: the AP only runs two plain commands. MACs are shortened
# to the last 5 hex digits, so the output is safe to paste.
# usage: watch-roam.sh <ap1-ip> <ap2-ip> [interval]
A=${1:?ap1 ip}; B=${2:?ap2 ip}; IV=${3:-5}
while :; do
	date '+%H:%M:%S'
	for h in "$A" "$B"; do
		ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$h" \
			'ubus call usteer local_info; echo ===; ubus call usteer get_clients' 2>/dev/null |
		AP="$h" python3 -I -c '
import json, os, sys
raw = sys.stdin.read().split("===")
ap = os.environ["AP"]
try:
    local = json.loads(raw[0]); clients = json.loads(raw[1]) if len(raw) > 1 else {}
except Exception:
    print("  %-14s (no answer)" % ap); raise SystemExit
roam = " ".join("%s=%d/%d" % (b.replace("hostapd.", ""),
                              v["roam_events"]["source"], v["roam_events"]["target"])
                for b, v in sorted(local.items()))
print("  %-14s roam src/dst: %s" % (ap, roam))
for mac, info in sorted(clients.items()):
    here = [(n, d) for n, d in info.items() if "#" not in n]
    if not any(d.get("connected") for _, d in here):
        continue
    for n, d in sorted(info.items()):
        tag = "HERE" if "#" not in n else "peer"
        print("      ..%s %-6s %-5s %4s dBm%s" % (
            mac[-5:], n.split("hostapd.")[-1], tag, d.get("signal"),
            "  <-- connected" if d.get("connected") else ""))
' || echo "  $h unreachable"
	done
	sleep "$IV"
done
