# Vibration monitoring

The admin dashboard monitors one digital vibration sensor on **BCM GPIO21 (physical pin 40)**. Wire VCC to 3.3V, GND to a ground pin, and DO to GPIO21. The installed board was observed idle LOW with brief HIGH pulses. The monitor uses active-HIGH input events and does not drive any output pins.

The existing lgpio package captures both edges so short pulses are not missed between dashboard refreshes. Rising edges are counted at most once every 100ms; **five accepted triggers within two seconds** latch a shaking alert. These are initial classroom-demo settings, not a calibrated force measurement. One sensor represents the whole enclosure, not an individual compartment. Tune the module's sensitivity knob after attaching it firmly inside the box.

The service listens continuously even while the browser is closed. The dashboard shows monitoring status, the current input level, recent/session trigger counts, last vibration and recent alerts. It refreshes every three seconds. **Clear alert** acknowledges the displayed alert with one click; it does not open a door or change inventory. A new burst can raise another alert. Alert history and uncleared alerts survive service restart; session counters restart at zero.

A lock command suppresses sensor counts for two seconds immediately before its pulse to avoid counting the lock's own mechanical impact. This does not clear an existing alert. No buzzer or iPad changes are included.

## Enable on the Raspberry Pi

Add the following to `config/lockers.env`, which the station's user service already loads:

```sh
LOST_FOUND_VIBRATION_ENABLED=1
```

Then restart `lost-found-box.service`. Set the value to 0 to disable hardware monitoring. The default is disabled, so local development and tests do not access GPIO. If GPIO21 cannot be claimed or read, the dashboard displays Unavailable rather than claiming the sensor is monitoring. A steady logic level cannot prove that a wire remains connected.

## API

Authenticated `GET /api/admin/overview` includes `vibration`:

- `enabled`, `status` (`disabled`, `monitoring`, `alert`, `error`), `error`.
- `gpio`, `pin`, `active_level`, `input_level`.
- `window_seconds`, `threshold`, `debounce_ms`, `suppressed`.
- `recent_triggers`, `total_triggers` (this process), `last_triggered_at` (epoch seconds or null).
- `active_alert` (object or null), `events` (20 most recent alerts).

Alerts contain `id`, `triggered_at`, `trigger_count`, `cleared_at` (epoch seconds or null). SQLite retains up to 100 recent alerts.

`POST /api/admin/vibration/clear` with `{"alert_id":"<UUID>"}` returns `{"vibration":...}`. It uses the existing admin session and same-origin JSON guards. Repeating a completed acknowledgement is harmless; a stale ID cannot clear a newer alert.

## Verification

Automated tests use a fake GPIO event source and a temporary SQLite database. They cover pulse capture, event spacing, rolling threshold, suppression, clearing, restart persistence, input failures and resource cleanup. Live deployment checks read the sensor; no lock actuation is needed. Final sensitivity tuning uses actual gentle taps and deliberate shaking on the mounted enclosure.
