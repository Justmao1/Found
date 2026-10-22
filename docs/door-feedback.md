# Compartment 01 and 02 door feedback

The user confirmed that the lock connected to **BCM GPIO12, physical pin32**, belongs to compartment **01**. Its isolated dry-contact feedback is wired between GPIO12 and GND. The live input test observed both levels and a stable LOW after the user reported the latch closed. LOW is therefore configured as closed. This is latch feedback, not an item-presence detector.

Compartment **02** uses **BCM GPIO18, physical pin12**, with the same dry-contact connection to GND and LOW-closed interpretation.

The server continuously reads both contacts with internal pull-ups and independent 250ms stable debounce. A transition, stale sample or read failure cannot be presented as a confirmed closed door. Compartments 01 and 02 have configured sensors; 03–04 keep their existing manual confirmation. Each input has independent timing and error state, so movement or failure on one contact cannot change the other door status. Existing opening outputs17/26/13/5 and vibration input21 are separate.

Set `LOST_FOUND_DOOR_FEEDBACK_ENABLED=1` in the station's `config/lockers.env` and restart its user service. The default is0 for local development. Automated checks use injected fake inputs, never physical locks.

During deposit or collection, the iPad automatically reads the current operation while the visitor flow is visible and foregrounded. It shows **Door not closed**, **Door closed**, or a checking/unavailable state. Sensor-backed completion is enabled only with fresh closed feedback. Network failures, backgrounding and visit/server changes invalidate the prior reading. Read-only polling does not open a door, renew visitor activity, or automatically complete a transfer.

The visitor still confirms that the item was placed inside or removed. The backend independently verifies door closure before accepting that confirmation. A blocked completion preserves the operation, inventory and compartment assignment. A completed request can be replayed without affecting a newer owner even if the door later opens. Explicit staff reconciliation remains available for sensor failures and other interrupted workflows.

The admin dashboard shows door state separately from occupancy and opening-output levels. Offline readings are marked unavailable. Refreshing the dashboard or receiving a contact change never changes item ownership.

API additions appear on each compartment and visitor operation as `door`:

```json
{"enabled":true,"gpio":12,"pin":32,"state":"closed","level":0,"updated_at":1792670400.0,"error":null}
```

`state` is `closed`, `open`, `unknown`, `unavailable`, or `not_configured`. Unconfigured pins, levels and timestamps are null. The overview's existing `door_state` mirrors this state and capabilities indicate configured feedback, not proof of wiring continuity. A disconnected contact wire reads HIGH; software cannot independently distinguish that from an open latch. A stable LOW at boot is accepted after debounce, but item placement/removal still requires visitor confirmation.
