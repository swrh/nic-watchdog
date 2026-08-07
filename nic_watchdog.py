#!/usr/bin/env python3
"""NIC watchdog for r8169 silent-hang recovery.

Must be run as root: soft-reset (`ip link`) and hard-reset (`modprobe`)
remediation steps require root privileges. The systemd unit runs this
directly as root; there is no in-script privilege escalation.
"""

from __future__ import annotations

import argparse
import logging
import re
import signal
import subprocess
import sys
import time

log = logging.getLogger("nic-watchdog")

_shutdown = False


def _handle_signal(signum: int, frame) -> None:
    global _shutdown
    _shutdown = True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--iface", default="enp6s0", help="Network interface to monitor (default: %(default)s)")
    parser.add_argument(
        "--gateway",
        default=None,
        help="Gateway IP to ping. Default: auto-detected from `ip route show default`, "
        "falling back to nothing if detection fails (in which case this flag becomes required).",
    )
    parser.add_argument("--interval", type=float, default=15, help="Seconds between checks (default: %(default)s)")
    parser.add_argument(
        "--fail-threshold",
        type=int,
        default=4,
        help="Consecutive failed checks before escalating (default: %(default)s)",
    )
    parser.add_argument(
        "--cooldown",
        type=float,
        default=900,
        help="Seconds to back off after a remediation attempt before escalating again (default: %(default)s)",
    )
    return parser.parse_args()


def detect_default_gateway() -> str | None:
    try:
        out = subprocess.run(
            ["ip", "route", "show", "default"],
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return None
    match = re.search(r"default via (\S+)", out)
    return match.group(1) if match else None


def read_tx_packets(iface: str) -> int | None:
    path = f"/sys/class/net/{iface}/statistics/tx_packets"
    try:
        with open(path) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def probe_reachable(gateway: str) -> bool:
    result = subprocess.run(
        ["ping", "-c", "3", "-W", "2", gateway],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def soft_reset(iface: str) -> None:
    log.warning("Attempting soft reset of %s (ip link down/up)", iface)
    subprocess.run(["ip", "link", "set", iface, "down"], check=False)
    time.sleep(2)
    subprocess.run(["ip", "link", "set", iface, "up"], check=False)
    time.sleep(3)


def hard_reset() -> None:
    log.warning("Attempting hard reset (modprobe -r r8169 && modprobe r8169)")
    subprocess.run(["modprobe", "-r", "r8169"], check=False)
    time.sleep(2)
    subprocess.run(["modprobe", "r8169"], check=False)
    time.sleep(3)


def remediate(iface: str, gateway: str) -> None:
    soft_reset(iface)
    if probe_reachable(gateway):
        log.warning("Recovered after soft reset of %s", iface)
        return

    hard_reset()
    if probe_reachable(gateway):
        log.warning("Recovered after hard reset of r8169")
    else:
        log.error("Still unreachable after soft and hard reset; will retry after cooldown")


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stdout,
    )
    args = parse_args()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    gateway = args.gateway or detect_default_gateway()
    if not gateway:
        log.error("No gateway specified and auto-detection failed; pass --gateway")
        return 1
    log.info(
        "Starting nic-watchdog: iface=%s gateway=%s interval=%ss fail-threshold=%d cooldown=%ss",
        args.iface,
        gateway,
        args.interval,
        args.fail_threshold,
        args.cooldown,
    )

    fail_count = 0

    while not _shutdown:
        tx_before = read_tx_packets(args.iface)
        reachable = probe_reachable(gateway)
        tx_after = read_tx_packets(args.iface)

        if reachable:
            if fail_count:
                log.info("Gateway reachable again after %d failed check(s)", fail_count)
            fail_count = 0
            log.debug("Check OK: %s -> %s reachable", args.iface, gateway)
        else:
            fail_count += 1
            log.warning(
                "Check failed (%d/%d): %s -> %s unreachable",
                fail_count,
                args.fail_threshold,
                args.iface,
                gateway,
            )

            if fail_count >= args.fail_threshold:
                tx_advanced = (
                    tx_before is not None and tx_after is not None and tx_after > tx_before
                )
                if tx_advanced:
                    log.warning(
                        "tx_packets advanced during failed probe (%s -> %s); "
                        "NIC is transmitting, outage looks upstream. Skipping remediation.",
                        tx_before,
                        tx_after,
                    )
                else:
                    log.error(
                        "tx_packets did not advance during failed probe (%s); "
                        "treating as local NIC wedge, escalating.",
                        tx_before,
                    )
                    remediate(args.iface, gateway)

                fail_count = 0
                log.info("Entering cooldown of %ss before further escalation", args.cooldown)
                _sleep_interruptible(args.cooldown)
                continue

        _sleep_interruptible(args.interval)

    log.info("Received shutdown signal, exiting")
    return 0


def _sleep_interruptible(seconds: float) -> None:
    end = time.monotonic() + seconds
    while not _shutdown and time.monotonic() < end:
        time.sleep(min(1.0, end - time.monotonic()))


if __name__ == "__main__":
    sys.exit(main())
