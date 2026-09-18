#!/usr/bin/env bash
# Build a .deb package for nic-watchdog.
#
# Usage: build-deb.sh <version> <arch> [package_revision]
#   <version>           upstream tag, e.g. v0.1.0
#   <arch>              amd64 | arm64 | all
#   [package_revision]  our packaging revision for this upstream version
#                        (Debian "debian_revision" convention). Defaults to 1.
#                        Bump this to publish a new .deb for the same
#                        upstream nic-watchdog version, e.g. after a packaging-only
#                        fix, without waiting for a new upstream release.

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <version> <arch> [package_revision]" >&2
  exit 1
fi

version="$1"
arch="$2"
package_revision="${3:-1}"

# Image used only to run dpkg-deb so package building is reproducible
# regardless of host OS (this script is expected to work from macOS too).
# No --platform flag is needed anywhere in this script: dpkg-deb --build
# never executes the packaged binary, it only archives files, so the
# container's own native platform is irrelevant to the target arch.
build_image="${BUILD_IMAGE:-debian:13}"

case "$arch" in
  amd64|arm64|all) ;;
  *)
    echo "Unsupported arch: $arch (expected amd64, arm64, or all)" >&2
    exit 1
    ;;
esac

version_number="${version#v}"
deb_version="${version_number}-${package_revision}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$repo_root/dist"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

echo "Building package root for nic-watchdog ${deb_version} (${arch})"
pkgroot="$work_dir/pkgroot"
mkdir -p "$pkgroot/usr/bin" "$pkgroot/lib/systemd/system" "$pkgroot/DEBIAN"

cp "$repo_root/nic_watchdog.py" "$pkgroot/usr/bin/nic-watchdog"
chmod 755 "$pkgroot/usr/bin/nic-watchdog"

cp "$repo_root/nic-watchdog.service" "$pkgroot/lib/systemd/system/nic-watchdog.service"
chmod 644 "$pkgroot/lib/systemd/system/nic-watchdog.service"

doc_dir="$pkgroot/usr/share/doc/nic-watchdog"
mkdir -p "$doc_dir"
cp "$repo_root/debian/copyright" "$doc_dir/copyright"

changelog="$work_dir/changelog.Debian"
sed -e "s/__VERSION__/${deb_version}/g" \
    -e "s/__UPSTREAM_TAG__/${version}/g" \
    -e "s/__ARCH__/${arch}/g" \
    -e "s/__DATE__/$(date -R)/g" \
    "$repo_root/debian/changelog.template" > "$changelog"
gzip -9n -c "$changelog" > "$doc_dir/changelog.Debian.gz"

installed_size="$(du -sk "$pkgroot/usr" | cut -f1)"

echo "Writing control file"
sed -e "s/__VERSION__/${deb_version}/g" \
    -e "s/__ARCH__/${arch}/g" \
    -e "s/__INSTALLED_SIZE__/${installed_size}/g" \
    "$repo_root/debian/control.template" > "$pkgroot/DEBIAN/control"

deb_name="nic-watchdog_${deb_version}_${arch}.deb"
pkgroot_container="/work/pkgroot"

echo "Building ${deb_name} inside ${build_image}"
docker run --rm \
  -v "$work_dir:/work" \
  "$build_image" \
  dpkg-deb --root-owner-group --build "$pkgroot_container" "/work/${deb_name}"

mkdir -p "$dist_dir"
deb_path="$dist_dir/$deb_name"
cp "$work_dir/$deb_name" "$deb_path"

echo "Done: ${deb_path}"
