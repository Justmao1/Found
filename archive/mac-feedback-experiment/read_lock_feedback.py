#!/usr/bin/env python3
"""Read an isolated dry contact: blue -> GPIO5 (physical 29), white -> GND (30).

Only connect a verified voltage-free contact isolated from the lock power wires.
Contact continuity must be calibrated against the actual latch position.
"""

import argparse
from signal import pause


def report(feedback):
    if feedback.is_pressed:
        print("GPIO5（物理29）= LOW / 0；蓝白触点接通", flush=True)
    else:
        print("GPIO5（物理29）= HIGH / 1；蓝白触点断开", flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--watch", action="store_true", help="持续监测触点变化，Ctrl+C 退出")
    args = parser.parse_args(argv)
    from gpiozero import Button

    with Button(5, pull_up=True, bounce_time=0.05) as feedback:
        if args.watch:
            feedback.when_pressed = lambda: report(feedback)
            feedback.when_released = lambda: report(feedback)
        report(feedback)
        if args.watch:
            pause()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("监测结束")
