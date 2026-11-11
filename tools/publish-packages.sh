#!/bin/sh
# Stage an apk package repository for a CR8806 NSS release.
#
# Usage: publish-packages.sh <pages-repo-checkout> [buildroot]
#
# Copies only index + .apk files out of the buildroot's bin/ tree -- never
# images, never keys other than the public one. Does not run git.
set -eu

OUT=${1:?usage: publish-packages.sh <pages-repo-checkout> [buildroot]}
TOP=${2:-/home/fanha/nss-build/openwrt-nss}

TARGET=qualcommax/ipq50xx
ARCH=aarch64_cortex-a53
FEEDS="base luci packages nss"

[ -d "$TOP/bin/targets/$TARGET" ] || { echo "no bin/targets/$TARGET in $TOP" >&2; exit 1; }
REV=$(cat "$TOP/bin/targets/$TARGET/version.buildinfo")
[ -n "$REV" ] || { echo "empty version.buildinfo" >&2; exit 1; }
echo "revision: $REV"

copy_dir() {
	src=$1; dst=$2
	[ -d "$src" ] || return 0
	n=$(find "$src" -maxdepth 1 -name '*.apk' | wc -l)
	[ "$n" -gt 0 ] || { echo "  skip $dst (no .apk)"; return 0; }
	[ -f "$src/packages.adb" ] || { echo "  ERROR: $src has .apk but no packages.adb -- run 'make package/index'" >&2; exit 1; }
	mkdir -p "$dst"
	find "$src" -maxdepth 1 -name '*.apk' -exec cp -p {} "$dst/" \;
	cp -p "$src/packages.adb" "$dst/"
	[ -f "$src/index.json" ] && cp -p "$src/index.json" "$dst/"
	echo "  $dst: $n packages"
}

echo "staging into $OUT/$REV"
rm -rf "$OUT/$REV"
copy_dir "$TOP/bin/targets/$TARGET/packages" "$OUT/$REV/targets/$TARGET/packages"
for f in $FEEDS; do
	copy_dir "$TOP/bin/packages/$ARCH/$f" "$OUT/$REV/packages/$ARCH/$f"
done

# the public key, so anyone can trust this repo from a self-built image
cp -p "$TOP/public-key.pem" "$OUT/cr8806-nss-public-key.pem"

# refuse to ship anything that is not an index or a package
bad=$(find "$OUT/$REV" -type f ! -name '*.apk' ! -name 'packages.adb' ! -name 'index.json' || true)
[ -z "$bad" ] || { echo "unexpected files staged:" >&2; echo "$bad" >&2; exit 1; }

echo
echo "total: $(find "$OUT/$REV" -name '*.apk' | wc -l) packages, $(du -sh "$OUT/$REV" | cut -f1)"
echo "device will fetch: https://<pages-host>/$REV/targets/$TARGET/packages/packages.adb"
echo
echo "next (run yourself, in $OUT):"
echo "  git add -A && git commit -m \"packages: $REV\" && git push"
