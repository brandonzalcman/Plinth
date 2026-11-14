# Loyalty points

Plinth earns points for using it, and levels unlock alternate app icons and bar accent colours. It is local and private: no account, no network service, no analytics. With iCloud sync on, Mac and iPhone points add up; with it off, each device counts alone.

The rules live in `Sources/PlinthLoyalty` (Foundation only, part of the `PlinthCore` library, shared with the iOS app).

## Earning

| What | Points | Limit |
|---|---|---|
| First use of a day, on each platform | 10, plus 2 per streak day already held (bonus capped at 10) | once a day per platform (Mac and iPhone add together) |
| Sharing Plinth (a completed share) | 15 | 3 a day per platform |
| First pin, first bookmark, first split view, first Ask, turning on sync | 25 each | once per account, however many devices reach it |
| Earning on both a Mac and an iPhone | 50 | once per account |

The streak counts days of use on any device. Inviting friends is reserved (`LoyaltyEvent.invite`) and awards nothing until there is a server to count invites.

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

A device's points are a *ledger*: a dictionary of awards keyed by what was earned (`day:2026-03-10`, `share:2026-03-10:1`, `once:firstPin`), each worth a fixed number of points and written once. Keys hold a kind and a Gregorian date in the device's current time zone only, never a page, site or search. Two copies of one ledger merge by taking the larger value per key.

Totals merge the ledgers of the same platform key by key first, then add the platforms. So a day of use and a share count once per platform per day: a reinstall (which gets a new device ID) or a second Mac does not earn the same day again, while a Mac and an iPhone add together. Milestone keys count once across everything. Two devices earning offline never overwrite each other.

Each device writes only its own `Loyalty` record (`loyalty-<device id>`) in the private iCloud zone and reads the others'. Before every upload, and again on a save conflict, the engine merges the server's copy of its own record into the local one, so nothing on the server is overwritten.

Limits that bound what a damaged or edited ledger can do: a single award is at most 100; unknown keys and days more than 2 days ahead are ignored; encoded ledgers over 900 KB are ignored. Today's day is awarded on any reading if the platform does not already have it, whatever the gap since the last use, so weekday-only or every-other-day use is paid on every used day. Keys more than 2 days after today are ignored in totals, so a wrong clock reading writes a key that simply does not count until its date. Changing the clock in either direction can mint days. There is no cap on the number of keys, because a cap would have to drop some and could lower a total; a ledger grows by about 35 bytes a key, well inside CloudKit's record limit for years. With no server, points cannot be made tamper-proof: stepping the clock a day at a time can farm points (about 145 clock changes reach the top level), and this is accepted rather than punishing normal use.

Points can be turned off: `LoyaltyEngine.isEnabled = false` stops earning and the interface hides them; what was earned is kept.
