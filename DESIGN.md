# Design

## Source of truth
- Status: Active
- Last refreshed: 2026-10-22
- Primary product surface: a native SwiftUI app on a fixed iPad at a physical lost-and-found station. The device belongs to the station, not to each visitor. iPhone is a compatibility/testing surface, not the primary product.
- Evidence reviewed: native station/Report/AppStore/PhotoCapture source and simulator screenshots; existing backend contract; current Apple HIG Materials, Motion, Accessibility, Sheets, and SwiftUI Liquid Glass documentation. Refreshed for the user's request for richer native visual and motion design.
- User-confirmed positioning: one shared, fixed device at the lost-and-found location; this is not an app distributed to each individual user.
- Implemented station shell: two-task home, explicit visitor sessions, camera-first Report, Find with inventory browsing, and protected staff tools.
- User-confirmed operating model: visitors operate the station themselves. Four electromagnetic locks represent compartments 01–04; visitors explicitly confirm placement/collection and closing the door. Staff reconcile interrupted operations and maintain the device. See `docs/locker-flow.md` for the state/API contract.

## Brand
- Personality: calm, helpful, practical. Retain the Found name and green accent; Report uses task-oriented native copy rather than marketing slogans.
- Home branding: reuse the existing green-square/white northeast-arrow AppIcon artwork as the bundled `FoundBrandMark` image, beside the “Lost & Found” welcome heading. It is a noninteractive brand mark, hidden from VoiceOver beside the readable title; stack it above the heading at accessibility text sizes.
- Trust signals: real connection state, saved-photo confirmation, visible tagging state.
- Avoid: invented locker status, ownership claims, fake inventory and unexplained AI confidence scores.

## Product goals
- Register physical items at the station using the fixed device's camera; preserve a failed submission for safe retry. The device photo library is a secondary import capability, not a visitor's personal library.
- Store one identified item in one free compartment; browse stored photos/tags and retry failed recognition independently of saving.
- Describe a lost item, compare actual stored matches, confirm the correct item, open its compartment and acknowledge collection.
- Non-goals: visitor accounts, cloud lock control and MQTT. Existing trusted-LAN access remains; staff tools use native device-owner authentication. A visitor ownership confirmation is not independent identity verification.
- Success: a person can complete a station task, understand the physical handoff, and leave the device ready for its next operator without carrying over another person's unfinished input.

## Personas and jobs
- Finders bring physical items to the station; owners come to the station to locate belongings.
- Staff maintain the station device, network connection and inventory, and physically verify interrupted deposit/retrieval operations before reconciling them.
- Visitors self-serve in short, separate sessions. Staff may recover uncertain uploads after device authentication; visitors do not access device configuration or the station photo library.

## Information architecture
- Primary navigation: home with “I found something” and “I lost something”. Each opens one focused task with Finish. Find links to browse items. Home has a secondary Staff entry and a noninteractive network indicator; no bottom tab bar or permanent sidebar.
- Report: capture → native review → saving in place → successful recognition → reserve/open a compartment → confirm item placed and door closed → stored receipt → an explicit task completion boundary. In-task image continuity and safe retry remain essential. A completed operator's receipt/draft must not become the next visitor's starting screen.
- The saved-photo screen shows actual AI tags directly beneath the photo, visible to the finder. Show a real tagging progress state until the existing server recognition completes, then update automatically. Failure/unavailable states preserve the saved receipt; the finder may retry tagging for this report. Only successful recognition permits allocation. Finish during a pending physical operation moves it to staff recovery without freeing the compartment. Before saving, explain that the tags appear after saving; never invent tags or silently upload an unsubmitted photo.
- Find: microphone first → recorded description → editable transcription → explicit search → candidate photos and reasons. Keyboard entry remains a visible secondary action. Once editing/reviewing a description, collapse the microphone hero to a compact action so the description and Find matches remain visible together in iPad landscape. Recording requires a deliberate tap and stops after 30 seconds; never listen automatically.
- Items: public browsing includes stored items eligible for retrieval. Staff inventory retains legacy/unassigned and collected records. Detail offers explicit ownership confirmation, one door-opening request and a separate collected/door-closed confirmation.
- Staff: LocalAuthentication deviceOwnerAuthentication gates setup, inventory maintenance, station photo import and pending-report recovery. Missing/failed authentication keeps tools locked. Authorization ends on close, backgrounding or inactivity; no hardcoded PIN.

## Design principles
- Native navigation, controls, sheets, pickers and accessibility semantics.
- A saved photo remains saved even if AI tagging fails.
- Clearly distinguish pending recognition, offline state, empty inventory and no matches.
- Keep backend setup in Settings; keep task screens focused on reporting and finding.
- Design for a shared fixed station: clear start/end boundaries, large discoverable actions, minimal setup required from visitors, and no personal-account or personal-history assumptions.
- Do not silently discard an in-flight or uncertain upload when returning to idle. Prevent stale photo/search completions from repopulating a later operator's session.

## Visual language
- Color: forest green accent derived from web #315c48, warm grouped surfaces, semantic system text; support dark mode.
- Typography: Dynamic Type system fonts with a strong title, short supporting sentence and clear action hierarchy. Use sentence case and native navigation titles. Avoid repeated uppercase headings and promotional slogans.
- Spacing/layout rhythm: 8/12/16/24 points; up to 1180 points for wide workspaces, 720 for a single reading column.
- Shape/radius/elevation: softly rounded content surfaces, subtle borders and small shadows for depth. Use opaque content cards; reserve Liquid Glass for functional controls on iOS 26, with native material/bordered fallbacks on iOS 17–18. Never stack glass content cards or place text on busy imagery.
- Motion: coordinated session entrances for title and content over a stationary backdrop: start at 72% opacity so the destination is immediately visible, then reach full opacity in a 0.16-second ease-out, while a small 12-point translation settles with a non-bouncy SwiftUI smooth spring (0.38-second perceptual duration). These values are project tuning, not Apple-mandated timings. Press feedback begins immediately (0.12 seconds) and releases softly (0.25 seconds); shorter local state changes and a single completion symbol response follow an acknowledged save. Animate only the new session surface; remove the outgoing session immediately, without retaining old visitor content. Do not stack page entrances on native push/pop transitions. Keep the selected photo stable through review/upload/success. No timers, fake upload percentages, delayed networking or decorative perpetual loops. Reduce Motion removes scale/translation and uses short fades; Reduce Transparency uses opaque controls.
- Imagery/iconography: actual item photos plus SF Symbols compositions that illustrate capture/search. Decorative item outlines are clearly illustrations, never pretend inventory. Keep text labels for actions and hide decorative artwork from VoiceOver.
- Recognized item categories use a local SF Symbols catalog shared by Report tags, inventory/search cards and item detail titles. Match only the first recognition tag (the backend's primary category); preserve the AI's original wording and order. Add the category icon to that first tag and item title, while color/feature tags remain text. Normalize common aliases and plurals conservatively; unknown categories use a generic item symbol. Symbols are bundled by the OS, with a generic runtime fallback if unavailable; no extra AI call or remote image download.

## Components
- Reuse: green accent, API contracts and established terminology. Web content hierarchy and card layouts are not design references for Report.
- Native components: station home task tiles, four numbered availability cells, Finish action, inactivity warning, pass-through touch activity observer, staff authentication sheet, focused report editor/photo acquisition, compartment operation card and staff reconciliation controls.
- Variants: disabled, processing, failed, saved, tagged; status uses text as well as color.
- Token/component ownership: extend `UI/Components.swift` for background, solid card surfaces, native action styles, press feedback and entrance motion. Avoid a separate design-system package.

## Accessibility
- Target: platform accessibility conventions, 44-point touch targets, Dynamic Type.
- Keyboard/focus behavior: multiline native fields, keyboard dismissal and submit actions.
- Contrast/readability: semantic secondary text, adaptive surfaces and accent.
- Screen-reader semantics: labeled images/actions, textual progress and results.
- Reduced motion and sensory considerations: no custom animation required for comprehension. Respect Reduce Motion, Reduce Transparency and Increase Contrast; do not animate sensitive content across a visitor reset.

## Responsive behavior
- iOS 17+, fixed iPad as the primary device, with landscape as the principal layout. Preserve narrow-window, portrait and accessibility support. Home task tiles sit side by side from 800 points; narrower windows and accessibility text sizes stack them. Existing task content uses the 820-point adaptive columns.
- Report uses a visual capture guide next to instructions on wide iPad and a system large sheet on iPhone / centered sheet on iPad. Photo preview adapts to sheet height and optional notes scroll naturally. Find places query beside guidance/results; detail places photo beside metadata; Items uses the full width for its adaptive grid; Settings groups connection controls beside setup help.
- Derive layout from available window width, including Split View/Stage Manager, rather than device identity. Use AnyLayout to retain form and picker identity across width changes.
- Adaptive grids wrap tags and inventory cards; large text can grow vertically.
- No hover-only actions; portrait and landscape supported.

## Interaction states
- Loading: show Preparing photo during import and Saving item while the save request is outstanding. Keep the photo visible and block duplicate saves, photo changes and dismissal during saving. Never couple save completion to list refresh or tagging.
- Empty: helpful explanation and relevant action; never replace errors with “no items”. Four occupied/reserved compartments show Full and ask for staff assistance; no fifth allocation is implied.
- Locker recovery: persist immutable request identity before transmission. Reads never actuate hardware. Response loss offers status lookup; a deliberate retry uses the same ID. Never auto-release a reserved slot on timeout/background/restart. Staff physically check before resolving stored/collected/empty. Hide previous visitor receipts at session end.
- Error: keep photo, note or search description; expose retry.
- Success: preserve photo continuity and distinguish Photo saved, Identifying, Preparing compartment, Ready to place/collect, and Stored/Collected. Show a prominent two-digit compartment number with a short physical instruction. A successful pulse is described as an opening command, not sensor-confirmed door motion. Finishing the task should deliberately return to a clean station entry. Finish returns to a clean home. There is no recent visitor history on home.
- Disabled: block save without a photo and empty search; explain unavailable camera/AI.
- Offline/slow network: bounded timeouts; keep current results with stale/error notice.
- Poll only while foregrounded and recognition is pending; ignore results from a previous server.
- Session boundary: Finish clears unsubmitted photo/note, query, search results, receipt and navigation; preserves server configuration and shared saved inventory. Session revisions reject old import/search completions.
- Voice: show permission, listening (real level and elapsed time), transcribing, editable result and recoverable error states. A second tap finishes recording; Cancel discards recording/transcription. Preserve existing description on failure. Leaving Find, backgrounding, changing servers or ending a session stops recording and rejects late permission/transcription callbacks. Interruptions stop capture without automatically resuming. Delete temporary recordings after capture/cancellation; no audio or transcript is stored by the backend. Disclose Alibaba Cloud transcription before recording. Respect reduced motion; no synthetic waveform or decorative looping animation.
- Inactivity: after 120 seconds without interaction show a 30-second warning with Keep Working / Finish Now. At 150 seconds reset to home. Touches and text changes renew activity; uploading and locker mutations cannot time out the visitor session and completion starts a fresh interval. Backgrounding resets once those requests finish; unresolved locker identity persists privately for staff.
- Uncertain upload: keep the immutable request privately in process for staff recovery; block another public report until resolved, while Find remains available. Never erase this retry copy automatically or present it to the next visitor. Staff can explicitly clear it after checking inventory. Process termination still loses in-memory recovery data.
- Deployment: foreground station stays awake. Guided Access/managed Single App Mode must be configured by the device owner; app navigation is not an OS lockdown.

## Content voice
- Tone: brief, friendly English consistent with the other native tabs; use direct task language.
- Terminology: “Photo saved”, “Tagging”, “Possible matches”.
- Microcopy: AI sends photos to Alibaba Bailian; visitors compare details and confirm which item is theirs. “I’ve placed it inside and closed the door” and “I’ve taken my item and closed the door” acknowledge physical completion. Uncertain opening results ask for staff assistance.

## Implementation constraints
- SwiftUI, Observation, PhotosUI, UIKit camera bridge and Foundation URLSession; no external dependencies.
- Existing Python backend and SQLite stay in place. AI credentials stay on the server.
- Voice uses AVAudioRecorder (16 kHz, mono, 16-bit PCM WAV) and a bounded `/api/transcribe` endpoint. Reuse the vision service's server-only key and Beijing host for `qwen3-asr-flash`; no Speech framework, new SDK or client API key. Validate WAV and request sizes server-side. Limit the editable description to the existing 500 Unicode code-point search contract.
- Normalize photos to JPEG, maximum 1600-pixel edge; keep immutable request ID/body on retry.
- Normal system TLS validation; no certificate-bypass delegate.
- Tests: API contract/error/idempotency tests, simulator build, native screen inspection and smoke flow.
- Compatibility: compile with installed Xcode 26.3; iOS 26 APIs behind availability checks. Current Apple design guidance informs the design, but newer SDK requirements must not be guessed or break iOS 17 support.

## Apple design references
- [Qwen ASR API](https://help.aliyun.com/zh/model-studio/qwen-asr-api-reference): synchronous DashScope audio input and Qwen3 transcription response.
- [Microphone permission](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)): request only after a visitor chooses to record.
- [Audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions): release capture on interruption; require a fresh deliberate start.
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials): glass on the functional layer; readable content surfaces.
- [Motion](https://developer.apple.com/design/human-interface-guidelines/motion): purposeful feedback and accessible transitions.
- [Animate with springs](https://developer.apple.com/videos/play/wwdc2023/10158/): no-bounce springs, context-specific tuning, perceptual duration, and separate timings for different animated properties.
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views): native glass APIs and interaction.
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility): readable scalable controls and reduced effects.

## Open questions
- [ ] Future bilingual UI preference; first version follows existing English UI.
- [x] Primary operator: visitor self-service (confirmed).
- [x] Initial idle policy: 120 + 30 seconds; staff access uses system device authentication. Timing can be adjusted after on-site use.
- [ ] Fixed camera mounting direction and capture area; do not force a camera orientation before this is known.
- [x] Physical claiming: four compartments 01→GPIO17, 02→GPIO26, 03→GPIO13, 04→GPIO5; all use S8050 inverters with LOW-trigger relay modules. GPIO5 is disconnected from the prior feedback contact plan. Completion uses deliberate visitor acknowledgement, not a door sensor.
- [ ] Distribution/device lock-down remains a deployment decision.

## IoT staff web console · 2026-10-22
- Additional product surface: `/admin/`, an English staff dashboard for the existing Raspberry Pi station. Follow `docs/iot-admin-contract.md`; retain the visitor iPad flow.
- Structure: desktop sidebar, overview with connection freshness and system telemetry, four compartment cards, searchable/paginated inventory, operation history and inspected recovery. Narrow screens stack cards and scroll tables without hiding controls.
- Reuse Found green and northeast arrow. Use local inline SVG icons with text labels, high-contrast status badges, subtle neutral surfaces, restrained charts of actual recent samples. No external fonts, packages, mock inventory, or fake sensor readings.
- Each manual opening requires an explicit compartment/reason confirmation; retain request identity on uncertain response, query without re-pulsing, and require a separate physical check before restoring availability. A manual opening does not collect an item. Door position is “Unknown (no sensor)”.
- Poll visible dashboards every three seconds with last successful update; show stale data and disable opening when disconnected. Preserve focused controls, dialogs and typed filters across refreshes. Administrator login uses HttpOnly cookie sessions; never store the password in web storage.
