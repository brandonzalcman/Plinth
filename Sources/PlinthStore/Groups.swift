import Foundation
import PlinthModel

// Site groups: plain rules, no model.
//
// The shell calls `noteCoOpen(seconds:)` every few seconds while the app is active. For every
// pair of site keys that sit on the same window's bar (pins are never on a bar, so never count)
// the pair's co-open time grows by that many seconds. A pair counts once per tick however many
// windows hold it, and one tick never adds more than `coOpenMaxTick` (so a missed timer or a
// sleeping Mac cannot add hours at once).
//
// Keeping the record small:
// - Decay: a pair that has not been co-open for `coOpenDecayInterval` (14 days) loses half its
//   time, and half again for every further 14 idle days. Pairs that fall under
//   `coOpenMinimum` (1 minute) are forgotten.
// - Cap: at most `coOpenPairCap` (500) pairs are written to disk, the longest co-open first. In
//   memory the table may grow to 1.5x that before being trimmed back, so new pairs get a chance
//   to accumulate instead of being trimmed the moment they appear.
// - Ticks do not save on every call: they schedule an autosave once `coOpenSaveInterval` of
//   co-open time has piled up since the last one (any other change saves sooner, and `flush`
//   writes everything at quit).
//
// A suggestion is the largest set of 2–5 sites on one window's bar in which every pair has been
// co-open for at least `groupPairThreshold` (20 minutes), that is not already a group (nor part of
// one), was not dismissed (nor part of a dismissed set), and leaves at least one other site on the
// bar to hide. Ties go to the set whose sorted hosts come first. No suggestion is made while the
// window is focused on a group.

/// An unordered pair of site keys, stored sorted by host.
struct CoOpenPair: Hashable, Sendable {
    let a: SiteKey
    let b: SiteKey
    init(_ x: SiteKey, _ y: SiteKey) {
        if x.host <= y.host { a = x; b = y } else { a = y; b = x }
    }
}

struct CoOpenStat: Equatable, Sendable {
    var seconds: TimeInterval
    /// Last time the pair was co-open, or the last decay step, whichever is later.
    var updatedAt: Date
}

/// On-disk form of one co-open pair.
struct CoOpenRecord: Codable, Sendable, Equatable {
    var a: String
    var b: String
    var seconds: TimeInterval
    var updatedAt: Date
}

extension BrowserStore {
    /// Every pair in a suggested set must have been co-open at least this long.
    nonisolated public static let groupPairThreshold: TimeInterval = 20 * 60
    nonisolated public static let groupMinSites = 2
    nonisolated public static let groupMaxSites = 5
    /// One `noteCoOpen` call never adds more than this.
    nonisolated public static let coOpenMaxTick: TimeInterval = 60
    /// Pairs kept on disk.
    nonisolated public static let coOpenPairCap = 500
    /// Idle time after which a pair's co-open time halves.
    nonisolated public static let coOpenDecayInterval: TimeInterval = 14 * 24 * 60 * 60
    /// Pairs that decay below this are forgotten.
    nonisolated public static let coOpenMinimum: TimeInterval = 60
    /// Co-open time that may pile up between autosaves triggered by ticks.
    nonisolated public static let coOpenSaveInterval: TimeInterval = 5 * 60
    /// Dismissed sets remembered, most recent kept.
    nonisolated public static let dismissedSuggestionCap = 200
    /// At most this many site names appear in a group name before "+n".
    nonisolated public static let groupNameMaxSites = 3

    // MARK: - Co-open time

    /// Call every few seconds while the app is active.
    public func noteCoOpen(seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        let dt = min(seconds, Self.coOpenMaxTick)
        let t = now()
        var pairs = Set<CoOpenPair>()
        for w in windows where !w.isPrivate {
            let keys = Array(Set(w.sites.map(\.key)))
            guard keys.count >= 2 else { continue }
            for i in 0..<(keys.count - 1) {
                for j in (i + 1)..<keys.count { pairs.insert(CoOpenPair(keys[i], keys[j])) }
            }
        }
        for pair in pairs {
            var stat = coOpen[pair] ?? CoOpenStat(seconds: 0, updatedAt: t)
            stat.seconds += dt
            stat.updatedAt = max(stat.updatedAt, t)
            coOpen[pair] = stat
        }
        decayCoOpen(at: t)
        if coOpen.count > Self.coOpenPairCap * 3 / 2 { trimCoOpen(to: Self.coOpenPairCap) }
        refreshQualifiedPairs()
        coOpenUnsaved += dt
        if coOpenUnsaved >= Self.coOpenSaveInterval {
            coOpenUnsaved = 0
            scheduleAutosave()
        }
    }

    /// Accumulated co-open time for two sites (0 when unknown). For the shell's diagnostics and tests.
    public func coOpenTime(_ x: SiteKey, _ y: SiteKey) -> TimeInterval {
        coOpen[CoOpenPair(x, y)]?.seconds ?? 0
    }

    func decayCoOpen(at t: Date) {
        let interval = Self.coOpenDecayInterval
        var gone: [CoOpenPair] = []
        for (pair, var stat) in coOpen {
            let idle = t.timeIntervalSince(stat.updatedAt)
            guard idle >= interval else { continue }
            let periods = (idle / interval).rounded(.down)
            stat.seconds *= pow(0.5, periods)
            stat.updatedAt += periods * interval
            if stat.seconds < Self.coOpenMinimum { gone.append(pair) } else { coOpen[pair] = stat }
        }
        for pair in gone { coOpen[pair] = nil }
    }

    /// The longest co-open pairs first; ties by hosts so the order is stable.
    func rankedCoOpen() -> [(pair: CoOpenPair, stat: CoOpenStat)] {
        coOpen.map { (pair: $0.key, stat: $0.value) }.sorted { x, y in
            if x.stat.seconds != y.stat.seconds { return x.stat.seconds > y.stat.seconds }
            if x.pair.a.host != y.pair.a.host { return x.pair.a.host < y.pair.a.host }
            return x.pair.b.host < y.pair.b.host
        }
    }

    func trimCoOpen(to cap: Int) {
        guard coOpen.count > cap else { return }
        var kept: [CoOpenPair: CoOpenStat] = [:]
        for item in rankedCoOpen().prefix(cap) { kept[item.pair] = item.stat }
        coOpen = kept
    }

    func refreshQualifiedPairs() {
        let qualified = Set(coOpen.filter { $0.value.seconds >= Self.groupPairThreshold }.keys)
        if qualified != qualifiedPairs { qualifiedPairs = qualified }
    }

    func coOpenRecordsForSaving() -> [CoOpenRecord] {
        rankedCoOpen().prefix(Self.coOpenPairCap).map {
            CoOpenRecord(a: $0.pair.a.host, b: $0.pair.b.host, seconds: $0.stat.seconds, updatedAt: $0.stat.updatedAt)
        }
    }

    func loadCoOpen(_ records: [CoOpenRecord]) {
        coOpen = [:]
        for r in records {
            let a = SiteKey(r.a), b = SiteKey(r.b)
            guard !a.host.isEmpty, !b.host.isEmpty, a != b, r.seconds.isFinite, r.seconds > 0,
                  r.updatedAt.timeIntervalSinceReferenceDate.isFinite else { continue }
            let pair = CoOpenPair(a, b)
            if let old = coOpen[pair], old.seconds >= r.seconds { continue }
            coOpen[pair] = CoOpenStat(seconds: r.seconds, updatedAt: r.updatedAt)
        }
        decayCoOpen(at: now())
        trimCoOpen(to: Self.coOpenPairCap)
        refreshQualifiedPairs()
    }

    // MARK: - Suggestions

    /// The group to suggest for this window right now, if any. Deterministic. Ignoring it changes nothing.
    public func groupSuggestion(for window: WindowID) -> GroupSuggestion? {
        guard let w = self.window(window), w.focusedGroup == nil, !w.isPrivate else { return nil }
        var hasher = Hasher()
        for site in w.sites { hasher.combine(site.key); hasher.combine(site.name) }
        hasher.combine(qualifiedPairs)
        for g in groups { hasher.combine(Set(g.keys)) }
        hasher.combine(dismissedSuggestions)
        let signature = hasher.finalize()
        if let cached = suggestionCache[window], cached.signature == signature { return cached.result }
        let result = computeSuggestion(for: w)
        suggestionCache[window] = (signature, result)
        return result
    }

    private func computeSuggestion(for w: WindowState) -> GroupSuggestion? {
        var names: [SiteKey: String] = [:]
        for site in w.sites where names[site.key] == nil { names[site.key] = site.name }
        let keys = names.keys.sorted { $0.host < $1.host }
        let n = keys.count
        let maxSize = min(Self.groupMaxSites, n - 1)
        guard maxSize >= Self.groupMinSites else { return nil }

        var adjacent = Array(repeating: Array(repeating: false, count: n), count: n)
        var anyEdge = false
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) where qualifiedPairs.contains(CoOpenPair(keys[i], keys[j])) {
                adjacent[i][j] = true; adjacent[j][i] = true; anyEdge = true
            }
        }
        guard anyEdge else { return nil }

        let excluded: [Set<SiteKey>] = groups.map { Set($0.keys) } + dismissedSuggestions.map { Set($0) }
        var best: [Int] = []
        // Depth-first with increasing indices visits sets of one size in lexicographic host order,
        // so the first acceptable set of a size is the tie winner.
        func extend(_ current: [Int], from start: Int) {
            if current.count >= Self.groupMinSites, current.count > best.count {
                let set = Set(current.map { keys[$0] })
                if !excluded.contains(where: { set.isSubset(of: $0) }) { best = current }
            }
            guard current.count < maxSize else { return }
            for j in start..<n where current.allSatisfy({ adjacent[$0][j] }) {
                extend(current + [j], from: j + 1)
            }
        }
        extend([], from: 0)
        guard best.count >= Self.groupMinSites else { return nil }
        let chosen = best.map { keys[$0] }
        return GroupSuggestion(window: w.id, keys: chosen, siteNames: chosen.map { names[$0] ?? identity.siteName(for: $0) })
    }

    /// Remembers the set so it (and any part of it) is not suggested again. Nothing else changes.
    public func dismissSuggestion(_ suggestion: GroupSuggestion) {
        let set = Self.normalizedKeySet(suggestion.keys)
        guard !set.isEmpty else { return }
        dismissedSuggestions.removeAll { $0 == set }
        dismissedSuggestions.append(set)
        if dismissedSuggestions.count > Self.dismissedSuggestionCap {
            dismissedSuggestions.removeFirst(dismissedSuggestions.count - Self.dismissedSuggestionCap)
        }
        commit()
    }

    /// Creates the group (or returns the existing group with exactly these sites). Does not focus it.
    @discardableResult public func acceptSuggestion(_ suggestion: GroupSuggestion) -> GroupID {
        var keys: [SiteKey] = []
        for key in suggestion.keys where !key.host.isEmpty && !keys.contains(key) { keys.append(key) }
        guard !keys.isEmpty else { return GroupID() } // refers to nothing, like openPage on an unknown window
        if let existing = groups.first(where: { Set($0.keys) == Set(keys) }) { return existing.id }
        var given: [SiteKey: String] = [:]
        for (key, name) in zip(suggestion.keys, suggestion.siteNames) where given[key] == nil {
            given[key] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let names = keys.map { key in given[key].flatMap { $0.isEmpty ? nil : $0 } ?? identity.siteName(for: key) }
        let group = SiteGroup(keys: keys, name: Self.groupName(names), createdAt: now())
        groups.append(group)
        commit()
        return group.id
    }

    /// "Docs", "Docs & Mail", "Docs, Mail & Calendar", "Docs, Mail, Calendar +2".
    nonisolated public static func groupName(_ siteNames: [String]) -> String {
        let names = siteNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        switch names.count {
        case 0: return "Group"
        case 1: return names[0]
        case 2...groupNameMaxSites:
            return names.dropLast().joined(separator: ", ") + " & " + names[names.count - 1]
        default:
            return names.prefix(groupNameMaxSites).joined(separator: ", ") + " +\(names.count - groupNameMaxSites)"
        }
    }

    nonisolated static func normalizedKeySet(_ keys: [SiteKey]) -> [SiteKey] {
        Array(Set(keys)).sorted { $0.host < $1.host }
    }

    // MARK: - Groups and focus

    /// Groups with at least one site on this window's bar, in creation order.
    public func groups(in window: WindowID) -> [SiteGroup] {
        // A private window has no groups: they are made from, and name, normal browsing.
        guard let w = self.window(window), !w.isPrivate else { return [] }
        let keys = Set(w.sites.map(\.key))
        return groups.filter { $0.keys.contains(where: keys.contains) }
    }

    public func group(_ id: GroupID) -> SiteGroup? {
        groups.first { $0.id == id }
    }

    /// Shows only the group's sites (plus the site of the selected page) on this window's bar;
    /// nil shows everything again. Nothing is closed or shelved. Ignored for an unknown group or
    /// one with no site on this window's bar.
    public func setFocus(_ group: GroupID?, in window: WindowID) {
        guard let wi = windows.firstIndex(where: { $0.id == window }), !windows[wi].isPrivate,
              windows[wi].focusedGroup != group else { return }
        if let group {
            guard let g = self.group(group) else { return }
            let keys = Set(windows[wi].sites.map(\.key))
            guard g.keys.contains(where: keys.contains) else { return }
        }
        windows[wi].focusedGroup = group
        commit()
    }

    /// What the shell's Group and chip buttons call: focuses the group and, when the selected page
    /// sits on a bar site outside it, moves the selection to the group's most recently used page.
    /// `visibleSites` always keeps the selected page's site, so without this the site you were on
    /// when you pressed Group stays on the bar and the press seems to do nothing.
    public func showGroup(_ group: GroupID, in window: WindowID) {
        setFocus(group, in: window)
        guard let w = self.window(window), !w.isPrivate, w.focusedGroup == group, let g = self.group(group),
              let selected = w.selectedPageID, let current = w.site(containing: selected),
              !g.keys.contains(current.key) else { return }
        var best: Page?
        for site in w.sites where g.keys.contains(site.key) {
            for page in site.pages where best == nil || page.usage.lastUsed > best!.usage.lastUsed { best = page }
        }
        if let best { select(best.id, in: window) }
    }

    /// Deletes the group and clears any focus on it. The sites are untouched.
    public func deleteGroup(_ id: GroupID) {
        guard let gi = groups.firstIndex(where: { $0.id == id }) else { return }
        groups.remove(at: gi)
        commit() // normalizeFocus clears focus on it
    }

    /// Blank names are ignored.
    public func renameGroup(_ id: GroupID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let gi = groups.firstIndex(where: { $0.id == id }), groups[gi].name != trimmed else { return }
        groups[gi].name = trimmed
        commit()
    }

    /// The sites the bar shows: all of them, or while a group is focused only the group's sites
    /// plus the site of the selected page, in bar order.
    public func visibleSites(in window: WindowID) -> [Site] {
        guard let w = self.window(window) else { return [] }
        guard let focused = w.focusedGroup, let g = group(focused) else { return w.sites }
        let keys = Set(g.keys)
        return w.sites.filter { site in
            keys.contains(site.key) || (w.selectedPageID.map { id in site.pages.contains { $0.id == id } } ?? false)
        }
    }

    /// Clears focus on groups that are gone or have no site left in the window.
    func normalizeFocus() {
        for wi in windows.indices {
            guard let focused = windows[wi].focusedGroup else { continue }
            let keys = Set(windows[wi].sites.map(\.key))
            if let g = group(focused), g.keys.contains(where: keys.contains) { continue }
            windows[wi].focusedGroup = nil
        }
    }

    /// Load-time repair: unique ids, distinct keys, a name for every group, tidy dismissed sets.
    func sanitizeGroups() {
        var seen = Set<GroupID>()
        var kept: [SiteGroup] = []
        for var g in groups where seen.insert(g.id).inserted {
            var keys: [SiteKey] = []
            for key in g.keys where !key.host.isEmpty && !keys.contains(key) { keys.append(key) }
            guard !keys.isEmpty else { continue }
            g.keys = keys
            g.name = g.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if g.name.isEmpty { g.name = Self.groupName(keys.map { identity.siteName(for: $0) }) }
            kept.append(g)
        }
        if kept != groups { groups = kept }

        var sets: [[SiteKey]] = []
        for set in dismissedSuggestions {
            let normal = Self.normalizedKeySet(set.filter { !$0.host.isEmpty })
            guard !normal.isEmpty else { continue }
            sets.removeAll { $0 == normal }
            sets.append(normal)
        }
        if sets.count > Self.dismissedSuggestionCap { sets.removeFirst(sets.count - Self.dismissedSuggestionCap) }
        if sets != dismissedSuggestions { dismissedSuggestions = sets }
    }

    func groupProblems() -> [String] {
        var problems: [String] = []
        var ids = Set<GroupID>()
        for g in groups {
            if !ids.insert(g.id).inserted { problems.append("duplicate group id (\(g.name))") }
            if g.keys.isEmpty { problems.append("group \(g.name) has no sites") }
            if Set(g.keys).count != g.keys.count { problems.append("group \(g.name) lists a site twice") }
            if g.name.isEmpty { problems.append("group with empty name") }
        }
        for w in windows {
            guard let focused = w.focusedGroup else { continue }
            guard let g = groups.first(where: { $0.id == focused }) else {
                problems.append("window focused on a group that does not exist"); continue
            }
            let keys = Set(w.sites.map(\.key))
            if !g.keys.contains(where: keys.contains) { problems.append("window focused on group \(g.name) with no site in it") }
        }
        if dismissedSuggestions.count > Self.dismissedSuggestionCap { problems.append("dismissed suggestions over their cap") }
        if coOpen.count > Self.coOpenPairCap * 3 / 2 { problems.append("co-open table over its cap") }
        return problems
    }
}
