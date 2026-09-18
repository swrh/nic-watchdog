# nic-watchdog

Self-healing watchdog for the `r8169` silent-hang bug seen on `apple`
(Lenovo Ideapad Z460, RTL8102e/RTL8103e on `enp6s0`): the NIC occasionally
wedges with `carrier`/`operstate` still reporting "up" and no kernel TX
watchdog firing, leaving the box unreachable until someone consoles in and
reloads the driver.

`nic_watchdog.py` runs as a persistent daemon that:

1. Periodically pings the default gateway to check reachability.
2. On repeated failures, checks whether `tx_packets` is still advancing.
   If it is, the NIC is fine and the outage is upstream — no action taken.
   If it isn't, this is the wedge signature: escalate to `ip link down/up`,
   and if that doesn't recover it, `modprobe -r r8169 && modprobe r8169`.
3. Backs off for a cooldown period after any remediation attempt to avoid
   a remediation storm.

## Requirements

- Python 3 (stdlib only, no third-party dependencies).
- Dependencies installed automatically via `.deb`: `python3`, `iproute2`, `iputils-ping`, `kmod`.
- Must run as root — `ip link` and `modprobe` require it.

## Install (.deb package)

Download the latest `.deb` package from the [Releases](https://github.com/swrh/nic-watchdog/releases/latest) page:

```sh
curl -LO https://github.com/swrh/nic-watchdog/releases/latest/download/nic-watchdog_<version>_amd64.deb
sudo apt install ./nic-watchdog_<version>_amd64.deb
```

Replace `amd64` with `arm64` on ARM systems, and `<version>` with the full version string (e.g. `0.1.0-1`).

After installation, enable and start the service:

```sh
sudo systemctl enable --now nic-watchdog
```

## Supported architectures

- `amd64`
- `arm64`

## Versioning

Package versions follow Debian's `<upstream_version>-<package_revision>` convention, e.g. `0.1.0-1`. `<package_revision>` identifies packaging revisions for the same version. A packaging-only fix can be re-released as `0.1.0-2`.

## How it works

1. **`scripts/build-deb.sh <version> <arch> [package_revision]`** stages `/usr/bin/nic-watchdog`, `/lib/systemd/system/nic-watchdog.service`, renders `debian/control.template` and changelog, and runs `dpkg-deb --root-owner-group --build` inside a `debian:13` Docker container. It works from macOS or Linux without local Debian packaging tools.
2. **`scripts/test-deb.sh <deb> <version>`** installs the built package in a distro container, verifies `nic-watchdog --help`, verifies systemd unit file presence, validates `dpkg` metadata, and confirms complete uninstall.
3. **`.github/workflows/release.yml`** builds `.deb` packages for `amd64` and `arm64`, runs tests in containers across Ubuntu (22.04, 24.04, 26.04) and Debian (12, 13) using QEMU, and publishes GitHub releases when git tags `v*` are pushed or via `workflow_dispatch`.

## Manual install

To run directly from a checkout without installing the `.deb`:

```sh
sudo ln -s "$PWD/nic-watchdog.service" /etc/systemd/system/nic-watchdog.service
sudo systemctl daemon-reload
sudo systemctl enable --now nic-watchdog
```

## Usage / options

```sh
nic-watchdog --help
```

- `--iface` (default `enp6s0`)
- `--gateway` (default: auto-detected from `ip route show default`)
- `--interval` seconds between checks (default `15`)
- `--fail-threshold` consecutive failed checks before escalating (default `4`, ~1 min)
- `--cooldown` seconds to back off after a remediation attempt (default `900`)

Logs go to stdout at INFO level (DEBUG for successful checks), so under
systemd they land in `journalctl -u nic-watchdog`.

## License

[MIT](./LICENSE) — Copyright (c) 2026 Fernando Silveira.
