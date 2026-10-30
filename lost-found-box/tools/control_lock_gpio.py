#!/usr/bin/env python3
"""Pi 4B GPIO17/GPIO26 -> S8050 -> LOW-trigger relay.
BCM numbering: GPIO17 = physical pin 11; GPIO26 = physical pin 37.
HIGH activates the relay through S8050; LOW releases it.
"""

import argparse
import fcntl
import json
import math
from pathlib import Path
import signal
import sys
import time

PINS = {17: 11, 26: 37}


def duration(value):
    seconds = float(value)
    if not math.isfinite(seconds) or not 0.01 <= seconds <= 2:
        raise argparse.ArgumentTypeError("seconds must be between 0.01 and 2")
    return seconds


def interrupted(signum, _frame):
    raise SystemExit(
        f"Signal {signum}; attempting to restore selected GPIO LOW."
    )


def inspect(api, handle, gpio):
    chip = api.gpio_get_chip_info(handle)
    line = api.gpio_get_line_info(handle, gpio)

    if chip[3] != "pinctrl-bcm2711" or line[3] != f"GPIO{gpio}":
        raise RuntimeError(
            "Expected Pi 4B gpiochip0 and selected GPIO; refusing output"
        )

    if line[4]:
        raise RuntimeError(f"GPIO{gpio} is in use by {line[4]!r}")

    print(json.dumps({
        "chip": chip[3],
        "gpio": gpio,
        "physical_pin": PINS[gpio],
        "consumer": line[4],
    }), flush=True)


def drive(api, handle, gpio, fire, seconds):
    claimed = False

    try:
        api.gpio_claim_output(handle, gpio, 0, api.SET_PULL_DOWN)
        claimed = True
        edges = []

        if fire:
            print(
                f"GPIO{gpio} (physical {PINS[gpio]}): "
                f"HIGH for {seconds}s, then LOW; "
                "S8050 drives relay IN LOW.",
                flush=True,
            )

            started = time.monotonic()

            # One finite pulse; no automatic repetition.
            api.tx_pulse(
                handle, gpio,
                round(seconds * 1_000_000),
                50_000, 0, 1,
            )

            previous = 0

            while api.tx_busy(handle, gpio, api.TX_PWM):
                elapsed = time.monotonic() - started

                if elapsed > seconds + 2:
                    raise TimeoutError(
                        "Pulse timed out; attempting LOW cleanup"
                    )

                level = api.gpio_read(handle, gpio)

                if level != previous:
                    edges.append({
                        "seconds": round(elapsed, 4),
                        "level": level,
                    })
                    previous = level

                time.sleep(0.005)

        api.gpio_write(handle, gpio, 0)
        final = api.gpio_read(handle, gpio)

        if final != 0:
            raise RuntimeError(f"GPIO{gpio} did not read LOW")

        if fire and not any(edge["level"] == 1 for edge in edges):
            raise RuntimeError(
                "No HIGH sampled; do not automatically retry"
            )

        print(json.dumps({
            "gpio": gpio,
            "cycles": int(fire),
            "commanded_high_seconds": seconds if fire else 0,
            "gpio_samples": edges,
            "final_level": final,
            "door_open_verified": False,
        }), flush=True)

    finally:
        if claimed:
            try:
                if api.tx_busy(handle, gpio, api.TX_PWM):
                    api.tx_pulse(handle, gpio, 0, 0, 0, 1)
            finally:
                try:
                    api.gpio_write(handle, gpio, 0)
                finally:
                    api.gpio_free(handle, gpio)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--gpio", type=int, choices=PINS, required=True,
        help="BCM GPIO number: 17 or 26",
    )
    parser.add_argument(
        "--seconds", type=duration, default=0.07,
        help="pulse duration: 0.01 to 2 seconds; default 0.07",
    )

    action = parser.add_mutually_exclusive_group()
    action.add_argument(
        "--fire", action="store_true",
        help="one HIGH pulse, then LOW",
    )
    action.add_argument(
        "--off", action="store_true",
        help="set selected GPIO LOW",
    )

    args = parser.parse_args()

    import lgpio

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)

    lgpio.exceptions = True

    # Prevent simultaneous processes; no cooldown or timestamp checks.
    lock_file = (
        Path(__file__).resolve().parents[1]
        / "data"
        / f"lock-test-gpio{args.gpio}.lock"
    )
    lock_file.parent.mkdir(parents=True, exist_ok=True)

    with lock_file.open("a+", encoding="utf-8") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        handle = lgpio.gpiochip_open(0)

        try:
            inspect(lgpio, handle, args.gpio)

            if not (args.fire or args.off):
                print("CHECK ONLY: no GPIO output claimed or changed.")
                return

            drive(lgpio, handle, args.gpio, args.fire, args.seconds)

        finally:
            lgpio.gpiochip_close(handle)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        sys.exit(f"Test stopped: {error}. No automatic retry.")
