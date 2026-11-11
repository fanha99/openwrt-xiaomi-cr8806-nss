# OpenWrt for Xiaomi CR8806 with NSS hardware offload

OpenWrt builds for the **Xiaomi CR8806** (M79; IPQ5018 + QCN6122 + QCA8337)
with **Qualcomm NSS hardware offload** for Ethernet and Wi-Fi. NAT and routing
go through ECM, and PPPoE, 802.1Q VLANs and the ath11k Wi-Fi data path run in
the NSS firmware instead of on the CPU.

> [!WARNING]
> These are personal test builds, not OpenWrt releases. The first install
> needs a UART and writes to flash. A wrong step can leave the router
> unbootable. Keep the other firmware slot as your way back. No warranty.

- **Download:** [Releases](https://github.com/fanha99/openwrt-xiaomi-cr8806-nss/releases). Every release lists what changed,
  what was tested and the flashing steps.
- **Without NSS:** [fanha99/openwrt-xiaomi-cr8806](https://github.com/fanha99/openwrt-xiaomi-cr8806)
  is plain OpenWrt for the same router.
- **Upstream:** this repository is a fork of
  [kuncy7/openwrt-nss-edma](https://github.com/kuncy7/openwrt-nss-edma)
  (OpenWrt main + NSS for IPQ5018, kernel 6.18). The CR8806 board support is
  merged there.

## Branches

| Branch | What |
|---|---|
| `main` | The default branch: kuncy7's `c3po-tag-8021q` plus a few CR8806 commits. Releases are tagged here. |
| `testing` | `main` plus changes under test. They move to `main` once they have run well for a while, and go upstream as pull requests. |
| `cr8806-memtest` | `testing` plus debug-only commits (page_owner), for measuring. |
| `notes` | Test notes only, no OpenWrt tree (see below). |

**Test notes:** what was tried on the CR8806, why, how it was measured and what came
out. [`NOTES.md`](https://github.com/fanha99/openwrt-xiaomi-cr8806-nss/blob/notes/NOTES.md) covers the RAM and Wi-Fi tests and is in
Vietnamese. [`pr45-followup.md`](https://github.com/fanha99/openwrt-xiaomi-cr8806-nss/blob/notes/pr45-followup.md) has the steps for the
board PR review. The measuring scripts are in [`tools/`](https://github.com/fanha99/openwrt-xiaomi-cr8806-nss/tree/notes/tools).

## What you get

- Wired NAT/routing, PPPoE and VLANs offloaded to NSS.
- Wi-Fi offload on both radios: 2.4 GHz (IPQ5018) and 5 GHz up to HE160
  (QCN6122). About 930 Mbit/s download and 730-810 Mbit/s upload with one
  HE160 client.
- Dual boot kept: two rootfs slots (`rootfs` = mtd18, `rootfs_1` = mtd19). You
  can flash one slot and keep the other as a fallback.
- LuCI included in the release images. The images are built without a
  `files/` overlay: OpenWrt defaults, no root password, Wi-Fi off,
  LAN 192.168.1.1.

**Both DSA conduits are in use**, since `cr8806-nss-2026.11.08`: the `wan`
port rides the second CPU port (`eth0`) and the three `lan` ports stay on
`eth1`, so a routed flow crosses one conduit per direction instead of the same
one twice. A single conduit is a hard ceiling of 927-929 Mbit/s bidirectional;
two give 1104-1458. It took two DSA fixes - one opens the conduit of a
PHY-to-PHY CPU link (openwrt/openwrt#26511), the other stops a standalone
port's tag_8021q VLAN from being given to every CPU port, which used to flood
every routed frame to both of them - plus an `nss-tools` fix that arms every
GMAC DSA gave user ports. All five commits are **upstream** since
kuncy7/openwrt-nss-edma#68, so they are no longer carried here; building
kuncy7's tree gives you the same behaviour.

`main` is kuncy7's `c3po-tag-8021q` plus seven commits. What they change:
- The ath11k 256M NSS memory profile on by default for the CR8806.
- About 6.8 MiB of memory back: the host releases its RX buffers while the NSS
  firmware owns a GMAC, the BPF JIT is off, and USB and ext4 are out of the
  image.
- The feeds pinned to the revisions the images are built from, and the package
  repository that the images install from (see below).

The 1024-entry RXDMA ring for the 5 GHz QCN6122 radio (the 2.4 GHz radio
keeps 512) is upstream since kuncy7/openwrt-nss-edma#55. It stops the 5 GHz
RX ring from overflowing under upload bursts.

Older releases were built on earlier trees. Their notes list what each one
carries.

## Things to know

- **Memory is tight.** Linux sees about 169 MiB, and NSS plus the Wi-Fi
  firmware take most of it. Expect 20-30 MiB available at idle, and avoid
  large packages.
- **`ethtool -G` / `ethtool -L` on eth0/eth1:**
  - On releases up to `cr8806-nss-2026.10.26`, this hangs the network until a
    power cycle.
  - `main` refuses it with `-EBUSY` while NSS owns the port
    (kuncy7/openwrt-nss-edma#52).
- **5 GHz takes about a minute to come up** on channel 36 at 160 MHz, because
  the range includes DFS channels and needs a 60 s check.
- **Not tested yet:** NAT/router mode throughput, IPv6, many Wi-Fi clients,
  LEDs and buttons, CR8808/CR8809.

## Installing software

`apk` works out of the box on the release images:

```sh
apk update
apk add htop
```

- **Kernel modules and the NSS packages come from this repository's own
  package feed**, pinned to the exact build the image was made from. Upstream's
  `kmod-*` are built against a different kernel configuration, so they would
  not load here; the image does not point at them at all. The feed carries the
  modules the image was built with - for one that is not there, rebuild the
  tree with that module selected, or with `CONFIG_ALL_KMODS=y`.
- Userspace packages come from the OpenWrt snapshot feeds (about 10 000 of
  them), listed in `/etc/apk/repositories.d/customfeeds.list`.
- Use `apk add`, **not `apk upgrade`**. The snapshot feeds are rebuilt daily,
  and pulling newer core libraries over a pinned build is a good way to break
  it. Keep the kernel and `kmod-*` packages as they came.
- The feed is signed, and the matching public key is already in the image at
  `/etc/apk/keys/public-key.pem`, so nothing needs `--allow-untrusted`. If you
  build your own image and want to use the feed, take `public-key.pem` from the
  release assets and drop it into `/etc/apk/keys/`.
- Each build gets its own directory in the package repository, and old ones
  stay, so a router keeps installing packages that match the firmware it runs.

## Flashing (short version)

The full steps are in the release notes.

1. **Boot the initramfs.** Over UART (115200 8N1) in U-Boot:
   `tftpboot 0x44000000 <initramfs.itb>`, then `bootm 0x44000000#config@mp02.1`.
2. **Write the image.** From the initramfs, stream the `factory.ubi` into the
   slot that is not running:
   `ssh root@192.168.1.1 "ubiformat /dev/mtd19 -y -f - -S <size>" < factory.ubi`
3. **Switch to that slot.** Point the boot flags at it and reboot:
   `fw_setenv flag_last_success 1; fw_setenv flag_boot_rootfs 1; fw_setenv flag_try_sys2_failed 0; fw_setenv flag_ota_reboot 0; reboot`

If the router already runs OpenWrt, use `sysupgrade` with the
`sysupgrade.bin` instead.

## Building

Each release tag rebuilds its image: all feeds are pinned in
`feeds.conf.default`, and the release's `config.buildinfo` is the exact
configuration.

```sh
git clone https://github.com/fanha99/openwrt-xiaomi-cr8806-nss.git
cd openwrt-xiaomi-cr8806-nss
git checkout <release tag>
./scripts/feeds update -a && ./scripts/feeds install -a
cp <config.buildinfo from the release> .config
make defconfig
make -j$(nproc)
```

For how the NSS tree works, the two topologies, and how to port another
IPQ5018 board, see [README.ipq50xx.md](../README.ipq50xx.md).

## Updating from upstream, or if this repository stops being maintained

The CR8806 itself is supported in kuncy7's tree, so you can build that tree
directly: select `xiaomi_cr8806` under qualcommax/ipq50xx. The commits on
`main` here only add defaults and documentation, and `git log
upstream/c3po-tag-8021q..main` lists them. To carry them onto a newer
upstream:

```sh
git remote add upstream https://github.com/kuncy7/openwrt-nss-edma.git
git fetch upstream
git rebase upstream/c3po-tag-8021q main
```

`feeds.conf.default` pins every feed. After the rebase, drop the pins, or
point them at newer revisions. Then build as above, starting from the latest
release's `config.buildinfo`.

## Credits

[kuncy7](https://github.com/kuncy7) for the IPQ5018 NSS tree, and everyone it
builds on:
- Julius Bairaktaris, for `nss-edma-rework`.
- [Ziyang Huang (hzyitc)](https://github.com/hzyitc), for the first OpenWrt
  port to IPQ50xx ([openwrt-redmi-ax3000](https://github.com/hzyitc/openwrt-redmi-ax3000),
  Redmi AX3000 / Xiaomi CR880x) and IPQ5018 kernel patches still carried in this tree.
- George Moussalem, for the ipq50xx target.
- Robert Marko, for qualcommax.
- qosmio, for the NSS packaging.
- Qualcomm/CodeLinaro, for the NSS host components.

The full list is in [README.ipq50xx.md](../README.ipq50xx.md).

## License

GPL-2.0, see [LICENSE](../LICENSE). The NSS components keep their upstream
licenses.
