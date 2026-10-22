# Four-compartment station contract

> Current implementation and verification index: [technical documentation](technical/README.md). Backend and Swift code now exist, with isolated workflow checks recorded on 2026-10-22. This contract does not establish live deployment or physical acceptance.

Implementation plan, 2026-10-22. The station is a shared iPad with a Raspberry Pi backend. One item occupies one compartment. Visitors explicitly confirm physical completion; a relay pulse does not prove a door opened or an item moved.

## Hardware

User-confirmed BCM output mapping: 01 = 17, 02 = 26, 03 = 13, 04 = 5. All channels use S8050 NPN stages and LOW-trigger relay modules. GPIO5 is disconnected from the previously proposed feedback contact. GPIO LOW is inactive; a single 0.5-second HIGH pulse activates a relay. Compartment 01 separately uses an isolated latch-feedback contact on GPIO12 (physical32), with the other contact wire connected to GND. LOW corresponds to the user-confirmed latched position. Slots 02–04 have no feedback input. GPIO21 is reserved for vibration monitoring. Use lgpio and retain bounded pulses, inactive initialization/cleanup, no automatic retry, GPIO ownership checks, and a persistent cooldown. Automated tests use injected fake drivers and inputs; simulation is explicit and restricted to localhost.

## Lifecycle

1. Save photo with existing upload idempotency, then wait for successful recognition.
2. The active iPad report explicitly starts one deposit operation. The backend atomically reserves the first free slot whose cooldown has ended, persists the operation before the pulse, then returns its compartment number.
3. Show the photo, tags, compartment number and “I've placed it inside and closed the door”. For sensor-equipped 01, the iPad automatically updates Door not closed / Door closed and only enables completion on a fresh closed reading. Only visitor confirmation changes the item to stored and the compartment to occupied.
4. Voice/text search and public browsing show only stored items eligible for retrieval. Legacy photo-only records are retained for staff, never silently assigned a slot.
5. The owner selects a match, confirms ownership, then starts one retrieval operation. The slot remains occupied while the door is used.
6. “I've taken my item and closed the door” atomically marks the item collected and frees the slot, again requiring fresh closed feedback when configured. Completed items are excluded from search. Closing a door alone never marks an item collected or frees a slot.

App backgrounding, timeout, request loss and server restart never free a slot or automatically send another pulse. Pending command identity is saved before transmission; uncertain operations are recoverable from the server. Staff can reconcile an interrupted operation only after an explicit physical check. Old session callbacks must not start a new visitor's operation.

## HTTP contract

All mutations retain the existing JSON, size, same-origin and X-Requested-With checks. Request/operation IDs are canonical UUIDs. This is the existing trusted LAN station deployment, not a publicly exposed service.

- `GET /api/lockers`: `{enabled, driver, compartments:[{id,state,item_id,door}], operations:[operation]}`. Driver is `gpio`, `simulated`, or `disabled`. Operations lists unresolved operations. Slot states: `free`, `reserved`, `occupied`, `retrieving`, `recovery`.
- `POST /api/locker-operations`: `{request_id,item_id,kind}` with `kind` = `deposit` or `retrieve`; returns `{operation,item}`. Same request and payload replays state without another pulse; payload conflicts fail. No capacity, unavailable hardware or inappropriate item state produce explicit errors.
- `GET /api/locker-operations/<id>`: `{operation,item}`; read only, never opens a door.
- `POST /api/locker-operations/<id>/complete`: `{}`; idempotent physical completion acknowledgement. Only awaiting-confirmation operations may newly complete. When its door sensor is configured, the backend independently requires a fresh stable closed reading; open/checking or unavailable feedback rejects completion without changing inventory. Replaying an already completed acknowledgement remains successful.
- `POST /api/locker-operations/<id>/resolve`: `{outcome}`; staff physical reconciliation. Deposit outcomes: `stored` or `empty`; retrieval outcomes: `collected` or `stored`. Never pulses. Resolution must be consistent with kind and live slot ownership; a completed operation cannot be reinterpreted.

Operation: `{id,kind,item_id,compartment_id,state,error,door}`; state = `actuating`, `awaiting_confirmation`, `completed`, or `uncertain`; error is nullable safe text. Item gains optional `compartment_id`; existing `status` becomes `recorded`, `deposit_pending`, `stored`, `retrieval_pending`, `collected`, or `recovery`. Existing item fields remain compatible.

The additive `door` object contains `enabled`, `gpio`, `pin`, `state`, `level`, `updated_at` (epoch seconds), and `error`. States are `closed`, `open`, `unknown`, `unavailable`, and `not_configured`. Unconfigured slots have `enabled:false`; missing `door` on an older server preserves manual confirmation. Raw contact transitions are debounced before reporting closed, and stale/failed samples cannot remain closed. See [door-feedback.md](door-feedback.md) for setup and limitations.

Only stored items with matching occupied slots can start retrieval. A unique active item/slot operation prevents distinct request IDs from bypassing replay protection. Persist `actuating` before GPIO; startup converts unresolved actuation to `uncertain`, never resumes it. Post-actuation errors reserve the slot for inspection. Public confirmation does not silently resolve uncertainty.

## Work and verification

- Backend: additive SQLite tables/migration, real GPIO driver, operation endpoints, stored-only public queries, transactional allocation and completion, durable recovery, targeted concurrency/crash/replay tests.
- iPad: typed API models, persistent pending command, session-safe state transitions, report allocation/placement, retrieval confirmation, four-slot availability and staff reconciliation using existing native components.
- Integration: exercise actual Swift client against a temporary Python backend with explicit fake GPIO, including all four slots, full capacity, retrieval/reuse and repeat requests.
- Validate Swift core tests, native AppStore tests, simulator build and visible iPad states; run Python regressions. Deploy with backup and verify read-only health/config/state on Pi. Do not actuate physical locks as part of automated checks.
