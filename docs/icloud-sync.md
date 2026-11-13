# iCloud sync

Status: built and tested against an in-memory server. It has **not run against CloudKit** yet.
Sync is **off by default**. In a build without an iCloud entitlement (no-team builds, and signed
releases made without the provisioning profile), the settings switch shows "iCloud sync needs a
developer team". The running app only checks for the entitlement
`com.apple.developer.icloud-container-identifiers`; it then uses the first container listed.

Code: `Sources/PlinthSync/`. Tests: `Tests/PlinthSyncTests/`.

## What syncs

| Synced | Not synced |
|---|---|
| Pins: site key, name, home URL, order | Windows, bars, splits, focus groups |
| Shelf: each shelved page (id, site key, site name, URL, title, name, custom name, shelved-at, last used) | A pin page's live state: current URL, scroll, usage, dwell |
| History: every entry (URL, title, name, key, visited-at, dwell), up to the newest 20,000 | Site stats, embeddings, downloads, settings |
| Each Mac's open pages, shown **read-only** on the other Macs | |

## Records

All records live in the user's **private** database, in a custom zone named `Plinth`. Every record
also has the fields `editedAt` (date: when the edit was made, by that Mac's clock), `editedBy`
(string: device ID) and `tombstone` (int 0/1).

| Type | Record name | Fields |
|---|---|---|
| `Pin` | `pin-<host>` | key, name, homeURL, order |
| `ShelfPage` | `shelf-<page uuid>` | pageID, key, siteName, url, rawTitle, name, customName?, shelvedAt, lastUsed |
| `HistoryEntry` | `history-<uuid>` | entryID, url, title, name, key, visitedAt, dwell |
| `HistoryClear` | `history-clear` | clearedAt |
| `Device` | `device-<device id>` | deviceID, deviceName, pages (JSON data) |

The device ID is a random UUID, created once per Mac and stored in user defaults
(`PlinthSyncDeviceID`). It is not tied to the hardware.

## Merge rules

The engine keeps a base, saved to `stateURL`. The base holds three things: the server records it
last saw (with their server versions), the records the local store was last known to match, and
the CloudKit change token. When the local store differs from the base, that is a local edit or a
local deletion. When the server differs from the base, that is a remote one. Each local edit is
timestamped when the engine first sees it (`recordLocalChanges`, which `scheduleSync` calls), not
when the next sync happens.

- **Pins.** Last writer wins per site key, by `editedAt`. Removing a pin writes a tombstone with
  its own time: the tombstone beats older edits and loses to newer ones, and a newer edit brings
  the pin back. The merged pins are ordered by the winning `order` field (ties go by host), then
  renumbered. The renumbering is uploaded in the same sync. When a pin is read back, the local pin
  with that key keeps its id and its page. A pin that is new to this Mac gets a fresh page at its
  home URL.
- **Shelf.** Last writer wins per page id. A page that leaves the shelf on one Mac (restored to a
  bar, or removed) becomes a tombstone, so it leaves the shelf on every Mac. Pages are regrouped
  into one entry per site key, so the same site shelved on two Macs becomes one entry. Pages are
  sorted newest-shelved first. If one entry ends up with two pages at the same URL, only the most
  recently used one is kept, and the other is tombstoned. Each page keeps the `shelvedAt` it was
  first synced with.
- **History.** Union by id. Sync never deletes history entries, and an entry removed on one Mac
  is not brought back to that Mac. The one exception is **Clear history** (`clearHistory()`): it
  writes the `history-clear` marker, and every Mac drops every entry visited at or before
  `clearedAt`. The Mac that cleared also deletes those records from the server. Only the newest
  20,000 entries are kept. The Mac that created an entry may update its title, name or dwell
  later, and that update syncs.
- **Open pages.** Each Mac writes only its own `device-<id>` record. It does so when its open pages
  change, and at least once a day. Other Macs' records are read-only and never saved. A record
  older than 30 days is ignored.
- **Ties.** When two edits have the same time, the tombstone wins. If they are still tied, the
  larger device ID wins. Every Mac picks the same winner.
- **Conflicts.** A save that the server refuses because the server copy changed in the meantime
  is merged again by the same rules and retried, up to 4 rounds per sync.
- **Idempotent.** A second sync with no changes uploads nothing.
- **Failures.** A sync that throws leaves the saved base untouched. Pending local edits keep
  their timestamps. If the change token has expired, the engine fetches everything again. If the
  zone is gone (the user reset their iCloud data), the engine forgets the server and uploads
  everything again.
- **Edits made while a sync is running.** `SyncCoordinator` applies the merged result only if the
  store did not change during the sync. If it did change, the coordinator calls
  `engine.mergeNotApplied()` and merges again (up to 3 times).

## Shell API

```swift
let settings = SyncSettings()                 // UserDefaults-backed; isEnabled defaults to false
settings.availability                         // .off | .needsDeveloperTeam | .ready(containerIdentifier:)
SyncSettings.isCloudKitConfigured             // true only with an icloud-container-identifiers entitlement
if let engine = settings.makeCloudKitEngine(stateURL: profileDir.appendingPathComponent("sync-state.json")) {
    let sync = SyncCoordinator(engine: engine)            // @MainActor
    // After any change to pins / shelf / history:
    sync.scheduleSync(local: { store.syncPayload }, openPages: { store.openPageSummaries },
                      apply: { store.applySync($0) })    // debounced, 5 s by default
    // On launch, on wake, or from a "Sync now" menu item:
    let result = await sync.syncNow(local: …, openPages: …, apply: …)  // Result<[DeviceOpenPages], Error>
    sync.otherDevices                                     // other Macs' open pages, read-only
}
// Clear history: clear the store, then
engine.clearHistory()
// Turning sync off: settings.isEnabled = false; engine.forgetServerState()
```

`makeCloudKitEngine` returns nil unless sync is on **and** the entitlement is present. No
`CKContainer` is created until the first fetch or save.

## Turning CloudKit on: what the owner must do

Each step needs the owner's own Apple Developer account. Most of the work is done in Xcode with `Plinth.xcodeproj`.

1. **Join the Apple Developer Program** (paid). CloudKit needs a team; a free personal team
   cannot use iCloud containers on macOS.
2. **Open `Plinth.xcodeproj`** and select the **Plinth** target, then **Signing & Capabilities**.
   - Choose your **Team**, keep "Automatically manage signing" on, and set **Signing Certificate**
     to "Development" instead of "Sign to Run Locally".
   - Xcode registers the App ID **`app.plinth.Plinth`** and creates a provisioning profile.
3. **Add the iCloud capability** with the **+ Capability** button.
   - Tick **CloudKit** and add the container **`iCloud.dev.getplinth.Plinth`** (Xcode creates it).
   - Xcode writes `com.apple.developer.icloud-services` and
     `com.apple.developer.icloud-container-identifiers` into `App/Plinth.entitlements`.
4. **Optional: add Push Notifications.** Other Macs would then hear about changes at once
   instead of at the next sync. The engine does not subscribe to pushes yet; adding a
   `CKRecordZoneSubscription` would be a follow-up.
5. **Run from Xcode** (⌘R), then turn on Plinth › iCloud Sync. Run
   `codesign -d --entitlements - <path to Plinth.app>` to confirm the container is listed.
   `SyncSettings.isCloudKitConfigured` then returns true.
6. **Deploy the schema** (next section).
7. **Distribute.** Releases are built by `Scripts/release.sh`, which adds the iCloud entitlement
   from `App/Plinth.release.entitlements` when it is given a Developer ID provisioning profile. The
   one-time account steps (container, App ID, profile, `DEVELOPER_ID_PROFILE` secret) are in
   [RELEASING.md](../RELEASING.md#icloud-sync-in-releases-optional). A signed build made
   without the profile has no iCloud, as before.
8. **Test with two Macs** signed into the same iCloud account. Turn sync on in both, pin a site on
   one, and check it appears on the other.

## Deploying the CloudKit schema

Xcode builds run against the **Development** environment, where CloudKit creates a record type the
first time a record of that type is saved. A Developer ID release runs against **Production**, which
has no types until you deploy them. The app never creates types in Production.

1. Run from Xcode with sync on (step 5 above). Make every record type appear in Development:
   pin a site (`Pin`), shelve a page (`ShelfPage`), visit a page (`HistoryEntry`), use **Clear
   history** once (`HistoryClear`, only written then), and wait for a sync (`Device`; it is written
   on the first sync). All five types must exist, or Production lacks the missing ones.
2. Open the CloudKit Console (icloud.developer.apple.com), choose container
   `iCloud.dev.getplinth.Plinth`, environment **Development**, and check Schema › Record Types for
   the five types above.
3. Choose **Deploy Schema Changes…** and confirm. This copies the types to **Production**. Deploy
   again after any later change to the records.

The `Plinth` zone is created by the app on first sync in each environment.

The SwiftPM route (`Scripts/bundle.sh`) still signs ad hoc and therefore never has iCloud. Use the
Xcode project for any signed build.

## Decisions to confirm

- Edit times come from each Mac's own clock. If a Mac's clock is wrong, its edits win or lose
  unfairly. The alternative is the server's modification date, but CloudKit sets that only when the
  record is saved, which loses the real time of an offline edit.
- Tombstones are kept forever. They are small, but they are never purged. A purge after, say, 90
  days would risk a Mac that has been offline longer than that bringing deleted items back.
- History is synced in full: up to 20,000 records, about 5–10 MB in CloudKit, and the first sync
  uploads all of it.
- On a Mac other than the one that shelved them, pages that were shelved together are sorted
  most recently used first. The order they had on the bar is not synced.
- Open pages are read-only on other Macs. Opening one creates an ordinary new page. The shell
  decides how that works.
