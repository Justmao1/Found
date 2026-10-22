# Verification history · 2026-10-20–22

Current status: [verification matrix](../docs/technical/05-verification-roadmap.md). Entries below retain their original test scope; later entries supersede earlier feature/deployment limitations.

Environment: Xcode 26.3 (17C529), iOS 26.3 simulator; app minimum deployment target iOS 17. No external package dependencies.

| Check | Result |
| --- | --- |
| iOS simulator app build | Passed |
| Swift Package Core tests | 21 passed, 0 failures |
| Native XCTest | 26 passed, 0 failures: 21 AppStore + 5 PhotoProcessor |
| Real Python backend integration | 10 HTTP checks passed; see `api-integration.txt` |
| Info.plist / Xcode project syntax, git diff whitespace | Passed |
| Native interface inspection | iPhone 17 Pro light/dark and large text, iPad mini portrait/landscape |

Latest native test evidence: `/tmp/found-station-final-tests.log` and the latest `.xcresult` in `/tmp/found-station-native/Logs/Test/`. Final UI build: `/tmp/found-station-build.log`. These temporary artifacts can be regenerated using the commands in the project README. An unused test-result warning was fixed after the run; the final app build only reports Apple's skipped AppIntents metadata extraction because the app does not use AppIntents.

## Verified behaviors

- Core request encoding, required headers, exact Content-Length, endpoint paths, decoding, server/network errors, cancellation, request timeouts and origin-limited images.
- URL validation rejects credential-bearing URLs, invalid ports and unexpected paths; HTTP is restricted to loopback development.
- Immutable upload request survives failure and is replayed byte-for-byte on retry. Failed upload preserves the photo and notes. Success clears the draft.
- Changing to a different server is blocked during an upload or pending retry. Rechecking the same server is allowed. Stale list/search responses cannot populate a new server.
- JPEG conversion rejects invalid data, bounds dimensions to 1600 pixels, preserves image orientation, handles EXIF rotation and composites transparency on white.
- Real backend upload, duplicate retry, 409 conflict, exact original-image retrieval, disabled AI 503, untagged search counts and query limit rejection.

## Native manual smoke

Used a temporary loopback Python server with an isolated database and AI disabled. No existing project records or cloud AI services were touched.

1. Settings → check connection: connected, empty inventory, AI unavailable.
2. Report → system Photos picker → select a generated test image labeled “TEST PHOTO · BLUE BOTTLE”. The image appeared in the preview.
3. Save item → “Photo saved” confirmation; the real Python service persisted the JPEG.
4. View saved item → original image loaded from the backend, saved date visible, AI-unavailable state correctly distinguished from save failure.
5. Find → enter a description → submit: “No tagged items yet” and “1 untagged item” displayed, matching the real backend response.
6. iPhone light/dark and iPad layouts inspected. Fixed white-on-mint prominent-button contrast discovered during dark-mode review.

`report-iphone.png`, `report-iphone-dark.png` and `report-ipad.png` show the native report screen. `item-iphone-dark.png` shows the explicitly labeled test image saved through the native app, not real inventory.

## iPad landscape and icon update

- Simulator build passed after the final layout fixes: `/tmp/found-ipad-layout.log`.
- Existing native regression suite rerun: 12 passed, 0 failures (`/tmp/found-ipad-layout-tests.log`). The subsequent changes only corrected Settings text wrapping and empty photo-preview height; the final build and visual checks cover those fixes.
- iPad mini landscape: icon sidebar, side-by-side capture/details and search/guidance, grouped Settings. Report's camera, photo-picker and save controls are visible together at the default text size.
- Rotated Find from landscape to portrait and back: the `12345` draft, character count and selected tab remained intact; portrait uses one column.
- Accessibility Extra Large: sidebar and two-column layout collapse to one column. Photo guidance grows to fit its text. This was a visual spot check, not a full accessibility audit. Restored the original Large text size afterward.
- iPhone 17 Pro: final build launches with one-column cards and native icon tabs.
- No backend or cloud requests were needed for the layout review; screenshots show the expected offline state.

Evidence: `ipad-landscape-report.png`, `ipad-landscape-find.png`, `ipad-landscape-settings.png`, `ipad-portrait-find-draft.png`, `ipad-accessibility-report.png`, and `iphone-adaptive-report.png`. `ipad-landscape-before.png` records the earlier single-column layout.

## Native Report flow redesign

- Final simulator build and 18 native tests passed. Six new AppStore regressions cover immediate acknowledged success without list refresh, duplicate count handling, the 100-item display limit, refresh failure after success, concurrent save protection, and a stale refresh racing the save acknowledgment.
- iPad landscape: system Photos picker → centered review sheet → enter note → Close → Continue Report preserves both image and note. Fixed an empty-preview regression by presenting an identifiable immutable photo snapshot. Save preserves the image in the receipt; View Item dismisses the sheet before opening the correct server-backed detail.
- iPhone: denied camera permission shows Settings/Cancel guidance; cancelling allows photo selection. Selected a simulator stock photo, entered a note, and saved with the isolated backend stopped. The error retained the draft and offered Retry Saving. Restarted the isolated backend and retried successfully.
- A six-second delay injected only in the temporary server verified visible indeterminate upload progress and disabled close/change/discard controls. Final progress styling retains readable contrast instead of fading the save label with a disabled button. No delay was added to the app.
- iPhone dark mode: reviewed confirmation, loading and saved states. Accessibility Extra Large: photo, change action, note and Save remain visible or scrollable. Restored Large text size, light appearance and the camera permission prompt afterward. This is a visual spot check, not a full accessibility audit.
- Temporary servers used isolated databases and disabled AI, then were stopped and cleaned up. No real inventory uploads or cloud calls were made. The iPad simulator’s original `https://work123.local:8443` setting was restored.
- Evidence: `report-ipad-review.png`, `report-ipad-saved.png`, `report-iphone-retry.png`, `report-iphone-review-dark.png`, `report-iphone-large-text.png`, `report-iphone-saved-dark.png`. The retry screenshot precedes the final shorter explanatory copy; behavior is unchanged. Earlier report screenshots above document the previous layout.

## Visitor self-service station

- Replaced the four-page navigation with a two-task home screen. iPad landscape tiles and portrait stacking inspected. Finish is visible on visitor task pages and in pushed browse/detail navigation.
- Entered a synthetic `12345` search description, finished the visit and reopened Find: the input was empty. No search request or inventory upload was submitted to the real server.
- Left Find idle with a synthetic description: the countdown warning appeared, expired to home, and the next visit had an empty description and 0/500 count. The state tests additionally cover Keep Working and exact time boundaries.
- Staff entry invokes the system device-passcode authentication screen; no settings are shown before authentication. Actual successful passcode/biometric authentication remains a physical-device check.
- Denied the simulator camera permission: the visitor alert offered Cancel and staff assistance, without an Open Settings action or photo-library fallback. Restored the original permission prompt afterward.
- Added eight state regressions for clearing visitor data while preserving station inventory/settings, discarded drafts, stale search/import isolation, failed-upload handoff and identical retry, inactivity boundaries and extension, upload protection, and server-change clearing. All 21 store tests plus five photo-processing tests passed.
- The final UI changes after the test run attach Finish inside navigation, retain warning controls through touch-up, and make toolbar text explicit. Final simulator build passed.
- Prior Report upload/retry evidence above remains relevant to the save pipeline; its previous Close/Continue/View Item navigation has been replaced by Finish & Return Home. The current visitor flow exposes camera capture only, with staff-only photo import.
- Simulator retained its original `https://work123.local:8443` address. Its untrusted-CA state is expected; certificate validation was not disabled and the server was not modified.
- Evidence: `station-ipad-home.png`, `station-ipad-report.png`, `station-ipad-new-visitor.png`, `station-ipad-staff-auth.png`. No real photos, real inventory mutations or cloud AI calls were used in this station review.

## Apple-native visual and motion refinement

Current visual evidence supersedes the earlier screenshots for appearance, not the historical behavior evidence above.

- Final production build passed with Xcode 26.3, iOS 17 deployment target (`/tmp/found-timeout-final-build.log`). Only Apple's unused AppIntents metadata extraction warning remains.
- Native tests: **26 passed, 0 failures** (`/tmp/found-visual-tests.log`; result bundle `/tmp/found-visual-native/Logs/Test/Test-Lost&Found-2026.10.20_20-00-23-+0800.xcresult`). The subsequent changes were limited to disabled-button contrast and the timeout layout. The final build and targeted UI checks cover these changes. No AppStore/API behavior changed in this refinement.
- Visually inspected the iPad landscape home and capture page, then review → acknowledged receipt → Finish & Return Home against an isolated loopback backend. A synthetic image marked TEST PHOTO was the only upload. The temporary server introduced a six-second delay solely for observing progress; no production delay, real inventory changes or cloud AI calls were used.
- During saving, native accessibility inspection confirmed disabled Finish and note editing, removal of the retake action, and visible saving progress. The photo remained on screen. The video captures the review/receipt/home flow; it is a simulator recording, not a frame-timing benchmark.
- Browse → fixture photo → Item Detail navigation was exercised. Visitor detail does not expose staff recognition retry. The next Find session started with empty input and 0/500 characters.
- Final iPad home inspected in light and dark appearance; iPhone portrait home also inspected for the stacked layout. The simulator was restored to Light and default Large text. The production app retains its original Raspberry Pi URL and system TLS validation; Offline in the screenshots is the simulator's existing untrusted-CA state.
- After the Mac was unlocked, exercised the production app at system AX5 size with synthetic search text. The real inactivity timer returned to Home; explicit Finish Now also returned Home before the countdown expired, and the next Find visit had empty input and 0/500.
- Follow-up appearance check showed Finish Now below the initially visible AX5 content. Moved both actions outside the scrolling message and hid the decorative symbol at accessibility sizes. In an isolated app using the unchanged production overlay/state types with a fixed countdown, both actions were visibly available; a coordinate tap on Finish Now returned Home. At default Large size the card retained its compact appearance, and a coordinate tap on Keep Working dismissed it while preserving the synthetic description. Scroll gestures were not reliably delivered by the simulator automation, so no gesture-scrolling pass is claimed; the iPad AX5 actions no longer require scrolling.
- This follow-up changed only `UI/StationSessionView.swift` and documentation/evidence. Final production build passed (`/tmp/found-timeout-final-build.log`), and `git diff --check` passed. The temporary fixed-countdown host was removed; its timing and defaults never entered the shipping app.
- Independent code review found no remaining API availability, visitor/staff, upload or session-reset issues. Reduce Motion/Transparency and increased-contrast branches were inspected in code; this turn did not exhaustively exercise those system settings. iPad portrait and real-device animation remain follow-up checks.
- Temporary visual-review app and server were removed after validation. The production app remains installed on the iPad simulator.
- Evidence: `native-visual-home.png`, `native-visual-home-dark.png`, `native-visual-iphone-home.png`, `native-visual-review.png`, `native-visual-saved.png`, `native-visual-timeout-ax5.png`, and `native-report-motion-landscape.mp4`.

## Task-entry motion · 2026-10-21

Historical iteration; timing and video are superseded by the responsive spring adjustment below.

- Unified the title/toolbar and page body under one session entrance, lengthened to 0.60 seconds with ease-in/out and an 18-point settling movement. A stationary backdrop stays underneath. Removed body-only entrances from Page/Home so native push/pop navigation does not add another entrance.
- Press feedback uses 0.14 seconds on contact and 0.34 seconds on release. Reduce Motion retains a 0.15-second fade with no translation or press scaling. The entrance task cancels if its session is replaced; no delayed navigation, networking or outgoing visitor snapshots were introduced.
- Build and all **26 native regressions passed** with no failures: `/tmp/found-motion-polish-tests.log`; result bundle `/tmp/found-motion-polish/Logs/Test/Test-Lost&Found-2026.10.21_08-33-15-+0800.xcresult`. `git diff --check` passed.
- On iPad mini landscape, exercised Home → Report → Finish → Home → Find → Finish → Home. Inspected successive recorded frames for both entries: title and content fade/move together over the same background. No previous-visitor content is retained. No photo upload or search was submitted.
- `station-task-motion.mp4` is a real-time simulator excerpt of the entry sequence, re-encoded at 60 fps for playback (not a device frame-rate benchmark). `station-task-motion-report-frames.png` and `station-task-motion-find-frames.png` show 0.1-second samples. Physical iPad motion feel and Reduce Motion runtime remain device checks; the latter's code branch was preserved.
- Changed implementation files: `ContentView.swift`, `UI/Components.swift`, `UI/StationHomeView.swift`. The final app remains installed on the iPad simulator at Home.

## Responsive spring adjustment · 2026-10-21

- Latest user feedback: the 0.60-second whole-page fade felt too slow. Consulted Apple HIG Motion and [Animate with springs](https://developer.apple.com/videos/play/wwdc2023/10158/). Apple gives no universal page-transition duration; the values below are project tuning.
- `UI/Components.swift`: a destination starts at 72% opacity and reaches full readability with a 0.16-second ease-out; its 12-point translation settles independently with `.smooth(duration: 0.38)` and no bounce. The title and content still enter together. Press/release durations are 0.12/0.25 seconds. Reduce Motion removes translation/scale and retains a 0.15-second opacity change. No interaction gate, request delay or outgoing-visitor snapshot was introduced.
- Final simulator build passed (`/tmp/found-responsive-motion-build.log`) and `git diff --check` passed. The 26 native regressions from the prior iteration remain the latest state/photo test run; this follow-up changes only animation presentation and was checked with targeted UI playback, without rerunning the unchanged state suite.
- Exercised Home → Report → Finish → Home → Find → Finish → Home on the installed production build in the iPad mini landscape simulator. Successive 0.05-second video samples show readable destination content immediately after the switch and the smaller settling motion. No capture, upload, inventory mutation or search was submitted.
- Current evidence: `station-responsive-motion.mp4`, `station-responsive-report-frames.png`, `station-responsive-find-frames.png`. The video uses original playback speed and was re-encoded at 60 fps for viewing; it is not a frame-rate benchmark. Physical iPad motion feel is still a device check.

## Remaining device validation

- Physical camera capture and allow/deny permission flows on a real iPhone/iPad.
- Real campus network, project Raspberry Pi hostname/IP and certificate trust.
- Staff passcode/Touch ID/Face ID success and Guided Access on the deployed iPad. Local staff authentication protects UI entry; the existing backend still has no authentication.
- Live Bailian recognition/search on the project deployment. Contract/error paths were tested without cloud requests.
- Full VoiceOver audit and the entire Dynamic Type range; semantic labels/native controls are present, but these were not exhaustively exercised.
- iOS 17 runtime itself; availability was checked by building with the iOS 17 deployment target, runtime testing used iOS 26.3.

No App Store packaging or distribution was attempted. Photos and retry payloads are retained for the current app process; this version does not persist unfinished drafts across termination.

## Finder-visible tags (2026-10-21)
- ReportEditorView now shows actual recognized tag chips directly below the saved photo, replacing the old “Item tags are ready” text. Existing polling supplies updates; failed tagging can be retried for this report without saving another item.
- Tags remain an after-save operation; review explains when they will appear. Finish remains available while recognition runs.
- Build passed: `/tmp/found-report-tags-build.log`; 39 native tests passed: `/tmp/found-report-tags-tests.log`.
- `report-recognized-tags-ipad.png`: isolated native iPad sheet preview with synthetic photo, ready tags and fixed Finish action. Temporary Python fixture exercised initial recognition failure and AppStore retry to success; no production writes or cloud recognition.
- Computer-use element selection was unavailable during this check, so button taps are not claimed. Preview-only initialization stayed in `/tmp`, outside production sources. Physical iPad and portrait not retested.


## Item category icons (2026-10-21)
- Added `Core/ItemCategory.swift`: 38 specific local categories plus a neutral fallback. Conservative English/Chinese aliases, plurals and short qualifiers match only the primary recognition tag. Specific compounds distinguish phone, phone case, phone charger, portable charger, notebook computer and key ring. The server response and original tag order/wording are unchanged.
- Shared `ItemCategoryLabel` and `TagList` put an SF Symbol next to the item title and first tag across Report receipt, inventory, search results and detail. Secondary color/feature tags remain plain text. Symbols are decorative to VoiceOver; a runtime generic fallback covers older OS symbol availability. No new dependency, network call or downloaded asset.
- Verification: 31 Swift package tests passed, including eight category-matching regressions (`/tmp/found-category-icons-swift-tests.log`). Full native suite passed 40 tests before the final symbol refinements (`/tmp/found-category-icons-tests.log`); the final production app rebuilt and the targeted catalog test passed with all 39 symbols available (`/tmp/found-category-icons-final-tests.log`). `git diff --check` passed.
- `item-category-icons-ipad.png` is an isolated iPad mini landscape catalog preview using the production mapping and TagList, with synthetic labels. Visually checked differentiated symbols, complete labels, tag spacing and the unknown-category fallback. Preview-only code stayed in `/tmp`; no real inventory mutations or AI calls were made.
- Removed the temporary preview app and restored the production build on the iPad simulator. Physical iPad and iOS 17 runtime were not retested.


## Green arrow on home (2026-10-21)
- Reused the existing AppIcon artwork as `Assets.xcassets/FoundBrandMark.imageset` and placed it beside the welcome heading in `UI/StationHomeView.swift`. The 64-point mark is decorative to VoiceOver; accessibility text sizes stack it above the heading. Updated the brand contract in DESIGN.md.
- Production simulator build passed (`/tmp/found-home-brand-build.log`). Inspected the installed app on iPad mini landscape in light/dark appearance and AX5, plus iPhone 17 Pro portrait. No clipping of the brand/header; normal iPad task cards remain fully visible. Screenshots: `home-brand-ipad.png`, `home-brand-ipad-dark.png`, `home-brand-ipad-ax5.png`, `home-brand-iphone.png`.
- Pure asset/header change; no new tests or repeated state suite. `git diff --check` passed. Restored the iPad to Light/default Large text; no inventory mutations. Physical iPad not tested.

## Four-compartment station · 2026-10-22

This entry supersedes earlier photo-only flow descriptions. A stored item now requires a completed deposit; collection requires its own explicit operation and physical-completion acknowledgement.

- Swift core: **42 tests passed**. Swift → real Python HTTP integration: **10 checks passed**, including four-slot capacity, replay protection, collection, release/reuse and exactly 10 simulated pulses (`locker-integration.txt`). Backend: **99 tests passed** both locally and in an isolated staging directory on the Raspberry Pi. No real GPIO pulses or cloud requests were used by these tests.
- Native suite: **51 tests passed**, zero failures/skips, iPhone 17 Pro simulator on iOS 26.3.1. Result: `/tmp/found-locker-native-tests/Logs/Test/Test-Lost&Found-2026.10.22_14-41-32-+0800.xcresult`. Regressions include durable command reload, disk-write failure preventing transmission, visitor isolation, busy/duplicate protection, canceled and stale refreshes, and historical acknowledgements not freeing a newly occupied slot. Later changes only adjusted detail navigation; final builds and runtime checks cover them.
- iPad mini landscape runtime: production views/state/client in a temporary app with an injected synthetic photo, isolated loopback database and mocked recognition/search. Exercised review → identified tags → assigned 01 → manual placement → stored receipt → Home showing three free. Typed search found the stored bottle; ownership confirmation led to collection. Returning from detail preserved a resumable collection panel. Confirming collection produced the receipt and Home with four free. A second run verified Browse → detail → collection without navigation popping after the source item leaves available inventory. Final fixture had four free slots and no unresolved operations.
- Visual review found and fixed clipped completion controls: deposit and collection actions are pinned to the safe area; saved-photo height is compact; deposit tags remain directly below the photo; active collection instructions appear first. Evidence: `locker-deposit-ipad.png` and `locker-collection-ipad.png`. These are default-size landscape spot checks, not a full accessibility/portrait audit. Preview-only initialization stayed outside production sources.
- A stale Home availability snapshot observed during idle recovery was corrected: operation responses immediately reconcile the affected compartment, old refreshes are invalidated, locker status publishes independently of the secondary inventory request, session changes refresh Home, and recognition polling no longer cancels itself when tags finish.
- Final signed device build and simulator build succeeded with Xcode 26.3, iOS 17 deployment target. Installed the final `AUT.Lost-Found` build on the paired physical iPad Pro (11-inch, fourth generation). Automatic launch was rejected because the iPad was locked; no successful physical-device UI session or real lock cycle is claimed. Installation log: `/tmp/found-locker-ipad-install.log`; launch diagnostic: `/tmp/found-locker-ipad-launch.log`.
- Raspberry Pi deployment completed with source/database backup, preserving all 12 old records, certificates and AI configuration. Trusted-CA HTTPS reads report GPIO driver enabled, four free compartments, zero operations, zero stored items and database integrity OK. All four GPIO outputs were initialized LOW with pull-down; no HIGH pulse was sent. Details and backup location are in `lost-found-box/VERIFICATION.md`.
- Removed the temporary preview app, stopped its loopback server, and restored the production app on the iPad simulator. No real inventory was mutated during visual verification.
- Remaining physical acceptance: camera/voice/cloud → real four-door operation, actual opening/reclosing, correct compartment wiring, and visitor placement/collection. Legacy records remain unassigned and available to staff; they do not appear as collectible locker contents. The backend still relies on the trusted LAN; local Staff authentication is not server authorization. Photo drafts remain process-only; locker commands use an atomic protected file journal.


## Two door inputs and registration recovery · 2026-10-22

Feature revisions: `2372432` (01 feedback), `f15c630` (completed-request reconciliation), `6875a0b` (02 feedback), `e722f21` (unfinished-step resume). This entry summarizes the recorded verification from those changes; the documentation update did not rerun the application or touch real inventory.

- First feedback change: **44 Swift Core tests**, **56 native tests**, **193 Python tests** and **12 HTTP workflow checks** passed. Signed iPad build, install and launch succeeded. The user confirmed the real iPad changes between open and closed as the 01 latch moves.
- Second feedback change: **196 Python tests** and **13 Swift/Python HTTP workflow checks** passed, with exactly ten simulated opening commands. Independent GPIO12 and GPIO18 debounce/error coverage verifies that closing 01 cannot complete a transfer in 02. The user then confirmed 02 status changes correctly in the interface. Slots 03–04 retain manual confirmation.
- Latest native regression run at 21:24: **62 tests passed, zero failures**. Coverage includes explicit GET-only resume, clearing a completed stale journal, retaining missing/offline/uncertain requests, canceling stale responses and checking fresh closed feedback. The signed `AUT.Lost-Found` build was installed and launched on the paired physical iPad Pro (11-inch, fourth generation).
- Latest simulator flow used an isolated fixture: enabled Home entry → continue unfinished 02 → open feedback blocks confirmation → closed feedback enables confirmation → explicit completion → Finish → new Report photo screen. The request audit contains exactly one POST, to `/complete`; there was no opening POST. The resume page does not expose the previous photo or note.
- Local evidence directories: `door-feedback/`, `two-door-feedback/`, `report-button-recurrence/`. Device logs, inventory snapshots and screenshots remain ignored; this tracked summary is the portable verification record.
- Backend source and both inputs were deployed; public/admin feedback agreed. User-confirmed latch transitions are narrower than full real-camera/AI/physical-deposit/collection acceptance. No real opening commands or inventory mutations were issued by this verification.
- The admin web surface now has password/session authentication; legacy visitor APIs still rely on the trusted LAN. Earlier “no backend authentication” statements describe the older deployment, not the current `/api/admin/` surface.
