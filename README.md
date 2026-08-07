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
- Must run as root — `ip link` and `modprobe` require it.

## Manual install

This repo checkout only contains the script and unit file; nothing is
installed or enabled automatically. To install on a box:

```sh
sudo ln -s /path/to/this/repo/nic-watchdog/nic-watchdog.service /etc/systemd/system/nic-watchdog.service
# or: sudo cp nic-watchdog/nic-watchdog.service /etc/systemd/system/
```

Edit the `ExecStart=` path in the unit file first to point at the actual
location of `nic_watchdog.py` on that box, then:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now nic-watchdog
```

## Usage / options

```sh
python3 nic-watchdog/nic_watchdog.py --help
```

- `--iface` (default `enp6s0`)
- `--gateway` (default: auto-detected from `ip route show default`)
- `--interval` seconds between checks (default `15`)
- `--fail-threshold` consecutive failed checks before escalating (default `4`, ~1 min)
- `--cooldown` seconds to back off after a remediation attempt (default `900`)

Logs go to stdout at INFO level (DEBUG for successful checks), so under
systemd they land in `journalctl -u nic-watchdog`.
