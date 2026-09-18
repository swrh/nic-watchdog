#!/usr/bin/env bash
# Install, smoke-test, and uninstall a built nic-watchdog .deb inside a distro
# container.
#
# Usage: test-deb.sh <nic-watchdog-deb> <expected-version>
# Intended to run as root inside an Ubuntu/Debian Docker container.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <nic-watchdog-deb> <expected-version>" >&2
  exit 1
fi

deb_path="$1"
expected_version="$2"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[[ -f "$deb_path" ]] || fail "deb file not found: $deb_path"

export DEBIAN_FRONTEND=noninteractive

# Official Ubuntu/Debian Docker images configure dpkg to skip installing
# man pages (and other docs) to keep images small.
rm -f /etc/dpkg/dpkg.cfg.d/excludes

apt-get update -qq || fail "apt-get update"

# Generic stock-package check: there is no "nic-watchdog" package in Debian/Ubuntu's
# official archives today, but check dynamically rather than hardcoding
# that assumption, so this script stays correct if that ever changes.
if apt-cache show nic-watchdog >/dev/null 2>&1; then
  echo "==> Stock 'nic-watchdog' package found in this distro's archive; installing it first"
  apt-get install -y nic-watchdog || fail "apt-get install (stock nic-watchdog)"
  command -v nic-watchdog >/dev/null 2>&1 || fail "nic-watchdog not found on PATH after installing stock package"
else
  echo "==> No stock 'nic-watchdog' package in this distro's archive; skipping upgrade-path setup"
fi

echo "==> Installing $deb_path"
apt-get install -y "./${deb_path}" || fail "apt-get install"

echo "==> Verifying installation"
hash -r
command -v nic-watchdog >/dev/null 2>&1 || fail "nic-watchdog not found on PATH after install"

echo "==> Running functional smoke test"
nic-watchdog --help >/dev/null || fail "nic-watchdog --help failed"

# Verify systemd service unit file is present
if [[ ! -f /lib/systemd/system/nic-watchdog.service && ! -f /usr/lib/systemd/system/nic-watchdog.service ]]; then
  fail "nic-watchdog.service not found in /lib/systemd/system or /usr/lib/systemd/system"
fi

dpkg -s nic-watchdog | grep -q "^Status: install ok installed" || fail "dpkg status for nic-watchdog is not 'install ok installed'"

echo "==> Uninstalling nic-watchdog"
apt-get remove -y nic-watchdog || fail "apt-get remove nic-watchdog"
hash -r

if command -v nic-watchdog >/dev/null 2>&1; then
  fail "nic-watchdog still present after removal"
fi

# A package with no conffiles (ours has none) is fully purged from dpkg's
# database by a plain "remove", so dpkg -s either reports it unknown or
# reports it in a non-installed (deinstall/config-files) state. Both are
# valid confirmations of removal; only "install ok installed" is a failure.
if dpkg -s nic-watchdog 2>/dev/null | grep -q "^Status: install ok installed"; then
  fail "nic-watchdog still reports as installed after removal"
fi

echo "PASS: all checks succeeded"
