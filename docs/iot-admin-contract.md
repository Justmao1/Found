# IoT administration contract · 2026-10-22

Add an English staff web console at `/admin/` beside the visitor iPad and legacy photo page. No third-party packages or remote assets. Forest-green Found branding, narrow desktop sidebar, readable data panels, four prominent compartment cards, responsive tables, calm status colors, reduced-motion support. Display actual telemetry and freshness; unsupported measurements use null/“Not available”. Physical door/contents sensor data is unavailable. Never equate a software state, pulse, or GPIO level with a measured door position.

Authentication: a separate administrator password, server-side sessions in HttpOnly SameSite=Strict cookie, Secure on HTTPS. Password never returned by HTTP or stored by the browser. Mutations retain JSON, request size, same-origin and X-Requested-With safeguards. Existing iPad APIs remain compatible with the trusted-LAN deployment. Admin endpoints do not make that legacy surface publicly safe.

## Web HTTP API
- GET `/api/admin/session` -> `{configured,authenticated}`.
- POST `/api/admin/login` `{password}` -> `{authenticated:true}` plus session cookie; POST `/api/admin/logout` `{}` expires it.
- GET `/api/admin/overview` -> schema below. Frontend polls every 3 seconds while visible, never overlaps, marks stale/offline and disables opening controls on connection loss. No polling opens a door.
- GET `/api/admin/items?q=&status=&offset=0&limit=25` -> `{items:[existing FoundItem],total,offset,limit}`. `q` searches note/tags/id; status empty means all records. Server pagination, status allowlist. Photo URLs remain same-origin `/images/<id>`.
- POST `/api/admin/manual-open` `{request_id,compartment_id,reason?}` -> `{operation,duplicate}`. Reason is optional, defaulting to "Manual opening". The UI sends no reason and opens with one click. Request UUID is persisted client-side before transmission and retained across uncertain responses; explicit retry uses identical payload. No automatic replay.
- GET `/api/admin/manual-open/<uuid>` -> `{operation}`; safe status lookup. POST `/api/admin/manual-open/<uuid>/confirm` `{}` finishes an uncertain or legacy pending manual operation and restores prior software state without another pulse. It never means an item was collected.
- POST `/api/admin/locker-operations/<uuid>/resolve` `{outcome}` wraps existing inspected recovery: deposit stored|empty, retrieve collected|stored.
- POST `/api/admin/items/<uuid>/recognize` `{}` requests tagging retry without another upload.

Manual operation: `{id,compartment_id,state,reason,created_at,error,item_id}`. `created_at` is epoch seconds; state is `actuating|awaiting_confirmation|uncertain|completed` (awaiting_confirmation is retained for existing records). During the pulse, the compartment is temporarily `maintenance`. On success, completing the command and restoring its previous software compartment state occur in one transaction. Item storage and visitor records are not changed; an unfinished visitor deposit/collection still needs its own completion. The UI displays a short “Opening command sent” toast, not a measured door state. No reason form or additional manual completion step is shown on success.

Use existing hardware locks, GPIO mapping, preflight, bounded pulse and cooldown; persist intent before pulsing. Crash, pulse or write failure retains maintenance and becomes uncertain without a repeat pulse. A separate command for that compartment is rejected while unresolved. A concise Finish action restores its previous software state without claiming collection or physical door closure. Restore cannot run during an active pulse. UUID replay always returns the original command without another pulse, including historical requests with reasons.

## Overview shape
```json
{
  "generated_at":"ISO UTC", "refresh_interval_seconds":3,
  "device":{"name":"Found Station","hostname":"...","model":"...","platform":"...","ip_addresses":[],"service_uptime_seconds":0,"system_uptime_seconds":null},
  "metrics":{"cpu_percent":null,"load_average":[],"cpu_temperature_celsius":null,"memory":{"total_bytes":null,"used_bytes":null,"percent":null},"disk":{"total_bytes":0,"used_bytes":0,"percent":0},"network":{"rx_bytes":null,"tx_bytes":null,"rx_bytes_per_second":null,"tx_bytes_per_second":null},"history":[]},
  "services":{"api":"online","database":"online","tls_enabled":false,"recognition":{"configured":false,"queue_depth":0,"pending_count":0}},
  "inventory":{"total":0,"stored":0,"collected":0,"recorded":0,"pending":0,"recovery":0,"recognition_pending":0,"recognition_failed":0},
  "lockers":{"enabled":true,"driver":"gpio","compartments":[{"id":"01","state":"free","item_id":null,"gpio":17,"pin":11,"output_level":null,"cooldown_remaining_seconds":0,"door_state":"unknown","item":null}],"operations":[]},
  "manual_operations":[],
  "activity":[{"id":"uuid","type":"deposit|retrieve|manual","compartment_id":"01","item_id":null,"state":"completed","created_at":0,"reason":null,"error":null}],
  "capabilities":{"door_sensor":false,"physical_feedback":false}
}
```
Each metric history point: `{at:ISO,cpu_percent,memory_percent,cpu_temperature_celsius,rx_bytes_per_second,tx_bytes_per_second}`. History is a bounded in-memory recent window, not fabricated history. Slot `item` is existing FoundItem or null. UI category name uses recognition.tags[0], fallback “Unidentified item”. Operation times in activity are epoch seconds. GPIO map 01=17/11,02=26/37,03=13/33,04=5/29 (BCM/physical).

## Verification
Backend regression for auth/session/CSRF validation, real telemetry null fallback, pagination, no secrets; manual command idempotency/cooldown/concurrency/crash/restore and exclusion from visitor inventory. Browser test against an isolated simulated server: login, data refresh, filter/search, one-click opening without a form or dialog, automatic software-state restoration, concise failed-operation recovery, lost-response status recovery, offline and narrow viewport. Existing iPad/core integration remains passing. Deployment backs up DB/source, avoids real pulse, verifies HTTPS reads. Real four-lock acceptance remains an on-site action.
