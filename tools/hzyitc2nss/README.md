# hzyitc2nss — convert an hzyitc OpenWrt config to the DSA/NSS build

`Convert-HzyitcConfig.ps1` turns a configuration backup taken on an
**hzyitc/openwrt-redmi-ax3000** build into a configuration for the
**DSA + NSS** build (Xiaomi CR880x / Redmi AX3000, upstream `qualcommax`
target).

Runs on Windows with the built-in PowerShell 5.1 and `tar.exe`; it only reads
the backup and writes files, it never touches a router.

## Why a converter is needed

|                | hzyitc build                                   | this build                          |
|----------------|------------------------------------------------|-------------------------------------|
| Base           | OpenWrt 23.05.3 (`r23809-234f1a2efa`), kernel 5.15, own `ipq50xx` target | OpenWrt main, `qualcommax/ipq50xx`  |
| Switch         | swconfig: `config switch` + `config switch_vlan` | DSA: `br-lan` + `config bridge-vlan` |
| Port names     | switch port numbers, `eth1.N` / `eth0.N`        | `lan1 lan2 lan3`, `wan`, `conduit`  |
| Radio `path`   | DT path of the 5.15 tree                        | `platform/soc@0/c000000.wifi`, `platform/soc@0/b00a040.wifi` |

Restoring the old backup on the new firmware therefore leaves the box with a
network config that does not describe its hardware: no bridge ports, no VLANs
and two radios that do not match any `path`, so Wi-Fi comes up with defaults
(or not at all).

Port mapping, from hzyitc's `target/linux/ipq50xx/base-files/etc/board.d/02_network`:

| board            | switch  | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 8 |
|------------------|---------|---|---|---|---|---|---|---|---|
| `redmi,ax3000` (CR880x M79, AX3000/CR880x M81) | switch1 | – | lan1 | lan2 | lan3 | wan | CPU `eth0` | CPU `eth1` | – |
| `xiaomi,cr881x`  | switch0 | lan1 | lan2 | lan3 | wan | CPU `eth0` | – | – | CPU `eth1` |
| `cmcc,rax3000q`  | switch1 | – | wan | lan1 | CPU `eth0` | lan2 | lan3 | CPU `eth1` | – |

## Use

```powershell
# 1. make the backup on the OLD firmware (LuCI: System > Backup, or on the box)
#    ssh root@192.168.1.1 sysupgrade -b /tmp/backup.tar.gz

# 2. convert it
.\Convert-HzyitcConfig.ps1 -Backup .\backup-OpenWrt-2026-11-06.tar.gz

# useful switches
.\Convert-HzyitcConfig.ps1 -Backup .\b.tar.gz `
    -SourceBoard redmi-ax3000 `   # the backup does not say which board it is
    -WanConduit eth0 `            # give the wan port its own CPU link
    -WithFirewall `               # also carry /etc/config/firewall
    -WithCredentials              # also carry the root hash + authorized_keys
```

Output in `-OutDir` (default `.\hzyitc2nss-out`):

| file | what it is |
|---|---|
| `etc\config\network`  | the converted network config |
| `etc\config\wireless` | the converted wireless config |
| `apply-on-router.sh`  | one script to run on the router; writes those two files, applies system/dhcp/dropbear with `uci`, and keeps a copy of the old `/etc/config` in `/root/config-before-convert-<date>` |
| `report.md`           | VLAN and port plan, SSID table, warnings, what was not carried over |
| `source-config\`      | the extracted backup, for reference |

**`apply-on-router.sh` contains the Wi-Fi passphrases** from the backup (and the
root password hash with `-WithCredentials`). Treat it like the backup: do not
commit it, do not post it.

Then:

```powershell
# flash the NSS build into the slot that is NOT running, do NOT restore the backup
# copy the script over (OpenWrt has no sftp-server, so scp does not work)
cmd /c "ssh root@192.168.1.1 ""cat > /root/apply.sh"" < hzyitc2nss-out\apply-on-router.sh"
```

```sh
# on the router
sh /root/apply.sh
cat /etc/config/network     # read it before applying
/etc/init.d/network restart && sleep 5 && wifi reload
```

Keep the other boot slot untouched until the new one has proven itself:

```sh
fw_setenv flag_last_success <other>; fw_setenv flag_boot_rootfs <other>; reboot
```

## What is carried over

* `system`: hostname, timezone, zonename, log and console options, NTP servers
* `network`: every interface that could be mapped — proto and its options
  (static/dhcp/dhcpv6/pppoe incl. username and password), DNS lists, IPv6
  assignment; VLANs become `bridge-vlan`, VLAN interfaces become `8021q`
  devices on `br-lan`
* `wireless`: radios matched **by band** (never by their old number or `path`),
  channel, htmode (`VHT*`/`HT*` are rewritten to `HE*`), country, plus every
  SSID with its encryption, key, network, ifname, hidden/isolate, 802.11r/k/v
  options
* `macaddr` of the bridge, of the VLAN devices and of each SSID — on by default,
  because the backup comes from the same unit and keeping them keeps the DHCP
  leases upstream stable. `-DropMacAddr` turns it off.
* `dhcp`: dnsmasq options, DHCP pools for interfaces that still exist, static
  leases
* `dropbear`: port and password-auth settings
* `firewall` with `-WithFirewall`; `network` entries that no longer exist are
  dropped and listed in the report
* root password hash and `authorized_keys` with `-WithCredentials`

## What is not

* `config switch` / `config switch_vlan` — swconfig does not exist on DSA
* LED configuration — the LED names differ between the two builds
* dropbear **host** keys (your SSH client warns once; copy them by hand from
  `source-config\etc\dropbear\` if you care)
* tunnels (wireguard, 6in4, …): the interface is reported and skipped
* package configs that only exist on the old build
* an `option gateway` the kernel could never install on that device: one on a
  `proto dhcp` interface (netifd ignores it), or one outside the interface's own
  subnet. Measured on a real backup: a spare port carrying
  an `ipaddr` on a /24 of its own plus `gateway <the LAN router>` — the gateway is
  not on-link there, so no route is ever installed, but LuCI still lists that
  interface as "IPv4 Upstream", and the day a cable goes into that port it
  becomes a second default route competing with the real uplink. Both cases are
  reported in `report.md` with the value, so you can put it back by hand if that
  interface really is the uplink. A gateway inside the interface's subnet is
  carried over untouched.

## Notes

* A backup does not record which board it came from, and the AX3000 and the
  RAX3000Q have overlapping switch-port numbers, so pass `-SourceBoard` when
  the unit is not a CR880x/AX3000.
* **One MAC per VLAN interface matters.** If several VLAN interfaces send DHCP
  requests with the same MAC, an upstream DHCP server hands out overlapping or
  changing leases. Where the backup has no MAC for a VLAN device the converter
  leaves a commented `option macaddr` for you to fill in.
* `-WanConduit eth0` puts the wan port on the second CPU link (2 × 1 Gbit in
  total instead of one shared gigabit). It needs a build that brings a
  PHY-to-PHY conduit up — this NSS build does.
* Tested against three synthetic backups (hzyitc default lan+wan, a VLAN trunk
  AP, and an all-ports-bridged dumb AP); the generated files were checked with
  `uci -c` on a real CR8806 and the apply script with `sh -n`.

## Dùng nhanh (vi)

1. Trên firmware cũ: LuCI → System → Backup, hoặc `sysupgrade -b /tmp/backup.tar.gz`.
2. Trên Windows: `.\Convert-HzyitcConfig.ps1 -Backup .\backup-....tar.gz`
3. Đọc `report.md` (bảng VLAN, cổng, SSID, cảnh báo) rồi mới áp dụng.
4. Flash bản NSS vào **slot không chạy**, **không** restore backup cũ, copy
   `apply-on-router.sh` sang router rồi `sh /root/apply.sh`.
5. Kiểm tra `/etc/config/network`, sau đó
   `/etc/init.d/network restart && sleep 5 && wifi reload`.
6. Giữ slot cũ làm đường về cho tới khi chắc chắn bản mới ổn.
