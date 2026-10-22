#!/usr/bin/env python3
"""One supervised lock-1 test: Pi 4B GPIO17 -> 3.3V-compatible HIGH relay.

The relay module must be configured for HIGH trigger and share GND with Pi.
Default: inspect only. --fire: one 0.5-second HIGH pulse, then LOW (off).
No door feedback is read. Software timing is not a hardware safety cutoff.
"""

import argparse
import fcntl
import json
from pathlib import Path
import signal
import sys
import time

GPIO = 17  # BCM numbering; physical pin 11
PULSE_US = 500_000
COOLDOWN_SECONDS = 30


def inspect_line(api, handle):
    chip = api.gpio_get_chip_info(handle)
    line = api.gpio_get_line_info(handle, GPIO)
    if chip[3] != "pinctrl-bcm2711" or line[3] != "GPIO17":
        raise RuntimeError("Expected Pi 4B gpiochip0 / GPIO17; refusing to drive.")
    if line[4]:
        raise RuntimeError(f"GPIO17 already belongs to {line[4]!r}; refusing to drive.")
    return {"chip": chip[3], "gpio": GPIO, "physical_pin": 11, "consumer": line[4]}


def pulse_once(api, handle):
    claimed = False
    try:
        api.gpio_claim_output(handle, GPIO, 0, api.SET_PULL_DOWN)
        claimed = True
        # Finite pulse count is essential: zero would mean continuous pulses.
        api.tx_pulse(handle, GPIO, PULSE_US, 50_000, 0, 1)
        started = time.monotonic()
        edges = []
        previous = 0
        while api.tx_busy(handle, GPIO, api.TX_PWM):
            now = time.monotonic()
            if now - started > 1.5:
                raise TimeoutError("Pulse did not finish within 1.5s; stopping output.")
            level = api.gpio_read(handle, GPIO)
            if level != previous:
                edges.append({"seconds": round(now - started, 4), "level": level})
                previous = level
            time.sleep(0.005)
        api.gpio_write(handle, GPIO, 0)
        final_level = api.gpio_read(handle, GPIO)
        if final_level != 0:
            raise RuntimeError("GPIO17 did not read LOW after the pulse.")
        if not any(edge["level"] == 1 for edge in edges):
            raise RuntimeError("No HIGH was observed; do not automatically retry.")
        return {"commanded_high_seconds": 0.5, "cycles": 1,
                "gpio_samples": edges, "final_level": final_level,
                "door_open_verified": False}
    finally:
        if claimed:
            # Try every cleanup action even if a preceding one fails.
            try:
                try:
                    api.tx_pulse(handle, GPIO, 0, 0, 0, 1)
                except api.error as error:
                    # lgpio can report this when the finite pulse has already
                    # finished. It is not a failure of the opening pulse.
                    if error.value != api.error_text(api.BAD_PWM_MICROS):
                        raise
            finally:
                try:
                    api.gpio_write(handle, GPIO, 0)
                finally:
                    api.gpio_free(handle, GPIO)


def interrupted(signum, _frame):
    raise SystemExit(f"Interrupted by signal {signum}; clearing GPIO17.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fire", action="store_true", help="pulse HIGH-trigger lock 1 once for 0.5s")
    args = parser.parse_args(argv)
    import lgpio

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    lgpio.exceptions = True
    handle = lgpio.gpiochip_open(0)
    try:
        print(json.dumps(inspect_line(lgpio, handle), ensure_ascii=False), flush=True)
        if not args.fire:
            print("CHECK ONLY: no GPIO output was claimed or changed.")
            return
        state = Path(__file__).resolve().parents[1] / "data" / "lock-test-gpio17.lock"
        state.parent.mkdir(parents=True, exist_ok=True)
        with state.open("a+", encoding="utf-8") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            stream.seek(0)
            saved = stream.read().strip()
            remaining = COOLDOWN_SECONDS - (time.time() - float(saved)) if saved else 0
            if remaining > 0:
                raise RuntimeError(f"Cooling down; wait at least {remaining:.0f}s.")
            stream.seek(0)
            stream.truncate()
            stream.write(str(time.time()))
            stream.flush()
            print("FIRING LOCK 1: one 0.5s HIGH pulse on GPIO17.", flush=True)
            print(json.dumps(pulse_once(lgpio, handle), ensure_ascii=False), flush=True)
    finally:
        lgpio.gpiochip_close(handle)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        sys.exit(f"Test stopped: {error}. No automatic retry.")
