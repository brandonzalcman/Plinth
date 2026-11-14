# Loyalty points

Plinth earns points for using it, and levels unlock alternate app icons and bar accent colours. It is local and private: no account, no network service, no analytics. With iCloud sync on, Mac and iPhone points add up; with it off, each device counts alone.

The rules live in `Sources/PlinthLoyalty` (Foundation only, part of the `PlinthCore` library, shared with the iOS app).

## Earning

| What | Points | Limit |
|---|---|---|
| First use of a day, on each device | 10, plus 2 per streak day already held (bonus capped at 10) | once a day per device |
| Sharing Plinth (a completed share) | 15 | 3 a day per device |
| First pin, first bookmark, first split view, first Ask, turning on sync | 25 each | once per account, however many devices reach it |
| Earning on both a Mac and an iPhone | 50 | once per account |

The streak counts days of use on any device.

## Levels

| Level | Name | Points | Unlocks |
|---|---|---|---|
| 1 | Footing | 0 | Sunrise icon and accent |
| 2 | Step | 100 | Dusk |
| 3 | Column | 300 | Meadow |
| 4 | Arch | 700 | Ember |
| 5 | Keystone | 1,500 | Midnight |
| 6 | Cornerstone | 3,000 | Mono |

The share card carries the level badge from level 1.

## How it merges

A device's points are a *ledger*: a dictionary of awards keyed by what was earned (`day:2026-03-10`, `share:2026-03-10:1`, `once:firstPin`), each worth a fixed number of points and written once. Keys hold a kind and a date only, never a page, site or search. Two copies of one ledger merge by taking the larger value per key, and the ledgers of different devices simply add up, so two devices earning offline never overwrite each other. Milestone keys count once across devices.

Each device writes only its own `Loyalty` record (`loyalty-<device id>`) in the private iCloud zone, and reads the others'. Values from other devices are bounded (a single award is at most 100, unknown keys and dates too far in the future are ignored), but with no server, points cannot be made tamper-proof.

Points can be turned off: `LoyaltyEngine.isEnabled = false` stops earning and the interface hides them; what was earned is kept.
