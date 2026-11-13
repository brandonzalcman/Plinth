# Version 1 build report

Nov 13, 2026. All seven remaining v1 items are built and wired. `swift build` is clean with no warnings, `swift test` passes 392 tests (up from 245), and `Scripts/bundle.sh` builds `build/Plinth.app`.

The app was checked on a throwaway profile against a local test server. Computer-use control of Plinth was declined, so clicks were made with the `PLINTH_STEPS` debug hook (`Sources/Plinth/DebugScript.swift`). It drives the same entry points the UI uses, including real `NSEvent` mouse clicks sent into the window, and takes window screenshots with `screencapture -l`.

## New modules

| Module | What it holds |
|---|---|
| `PlinthAI` | Chunker, chunk-and-summarise pipeline, resume cards, ask, semantic index, master switch, Foundation Models and NaturalLanguage implementations, fakes |
| `PlinthSync` | Record mapping, merge engine, in-memory and CloudKit transports, settings, coordinator |

Contracts live in `Sources/PlinthModel/Features.swift`. The pinned-link policy is `Sources/PlinthRules/PinLinkPolicy.swift`.

## Per feature: verified by running, or compiled only

1. **On-device AI.** The Foundation Models framework reports the model as *available* on this Mac.
   - **Ask page, run:** a question streamed an answer from the real model into the panel. The scope picker offers "This page", "All <site> pages" and "Compare split".
   - **Resume card, run:** shelving then restoring a site showed the loading card, then a real summary. Cards appear only on restore from the shelf.
   - **Semantic history, run:** pages with 30 s or more of dwell are embedded and stored in `semantic-index.json`, and "By meaning" results are returned.
     - The first run found nothing. NaturalLanguage sentence vectors of long body text drown short queries.
     - Fix: the index now also embeds the title and up to four short passages, and scores each page by its best match. Covered by tests.
   - **Master switch, run:** Plinth menu › Use On-Device AI. When off, ask shows "turned off" with a Turn On button, resume cards and indexing stop, and keyword search is unaffected.
   - **Ask ⌘J menu item, compiled only.** I did not see the "By meaning" rows in the command bar and shelf on screen; I checked only the results behind them.
2. **Group suggestions, run.**
   - After 20 minutes of co-open time, a "Group …?" pill appeared above the bar.
   - Accepting focused the group and hid the other site; "Show all" brought it back.
   - Not now: compiled only.
3. **Peek, run.**
   - A real ⇧-click on a link opened the preview card.
   - "Open as Page" turned the preview into a real page in that site's capsule, without reloading.
   - The context-menu items "Peek Link" and "Open Link in Split View": compiled only.
4. **Mini window, run.** `open -a Plinth.app <url>` opened the bar-less mini window, and promoting it moved the page into the main window's capsule. The ⌘⇧↩ shortcut and the on-window pill call the same code; they were not pressed by hand.
5. **Pinned sites, run.** In a pin, a real click on an off-site link opened an ordinary page and the pin stayed put. A same-site link navigated inside the pin. Sign-in links and redirects are exempt; that is unit-tested, not run.
6. **iCloud sync, compiled and unit-tested only** (49 tests on an in-memory transport). CloudKit cannot run in an ad-hoc signed build. It is off by default; Plinth menu › iCloud Sync explains why. Steps to turn it on are in `Design/icloud-sync.md`: developer team, App ID, container `iCloud.app.plinth.Plinth`, entitlements and signing.
7. **Smaller gaps**
   - **Split view menu, run:** View › Split View With (a submenu of pages) and View › Split View with Next Page (⌥⌘\\).
   - **Downloads indicator, run:** a real download finished and the indicator appeared above the bar on the right.
   - **Page under the title strip, run:** content starts below the strip; nothing is hidden under it.
   - **Passwords autofill:** not available without Apple's web-browser entitlement. Left as is.

## Also fixed or exercised (owner's report and never-tried items)

- **Window move and zoom, run.** The top strip is now a real drag area. Double-clicking it zoomed and restored the window, following the system's double-click setting. Moving the window by dragging the strip was not tried with a real drag.
- **Dragging on the bar.**
  - Reorder sites, reorder pages within a capsule, and drop one page on another to split: the bar agent saw all three working in the bar harness with real mouse events.
  - In the app, only the drag→store wiring was compiled, not tried.
  - Hover close buttons and rename were also seen working in the harness.
- **Split divider drag, run:** the split moved from 0.50 to 0.64.
- **Full-screen video, run:** element full screen hid the bar, and leaving it brought the bar back.
- **Find in page:** not re-tried.

## Decisions for the owner to confirm

- **Group thresholds:** 20 minutes of pairwise co-open time, 2–5 sites. Accepting also focuses the group immediately (one click to "Show all"). Dismissing a set also silences its subsets.
- **Mini window shortcut:** promote with ⌘⇧↩, and "Move to Main Window" is in the File menu.
- **Semantic search cut-off:** minimum score 0.3. Quality with NaturalLanguage embeddings is moderate, so "By meaning" stays a secondary section.
- **Sync:**
  - Edit times come from each Mac's own clock.
  - Tombstones are kept forever.
  - Full history syncs (up to 20,000 entries).
  - No push subscriptions; sync runs on change and at launch.
- **Peek trigger:** ⇧-click replaces WebKit's default ⇧-click behaviour.
- **Debug hook:** `PLINTH_STEPS` stays in the shipping binary but does nothing unless the variable is set.
