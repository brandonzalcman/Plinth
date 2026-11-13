import Foundation
import WebKit
import os

/// The built-in ad and tracker block list (`Resources/blocklist.json`), compiled once per
/// version of the file and cached on disk by `WKContentRuleListStore`.
public enum ContentBlocker {
    public enum BlockerError: Error {
        case missingResource
        case compiledToNothing
    }

    private static let identifierPrefix = "plinth-blocklist-"
    @MainActor private static var task: Task<WKContentRuleList, Error>?

    /// The compiled rule list. Concurrent callers share one compilation; a failure is not cached.
    @MainActor
    public static func ruleList() async throws -> WKContentRuleList {
        if let task { return try await task.value }
        let fresh = Task { @MainActor in try await load() }
        task = fresh
        do {
            return try await fresh.value
        } catch {
            task = nil
            throw error
        }
    }

    /// The raw rule-list JSON as shipped.
    public static func source() throws -> String {
        guard let url = Bundle.module.url(forResource: "blocklist", withExtension: "json") else {
            throw BlockerError.missingResource
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    @MainActor
    private static func load() async throws -> WKContentRuleList {
        let json = try source()
        let identifier = identifierPrefix + fnv1a(json)
        guard let store = WKContentRuleListStore.default() else { throw BlockerError.compiledToNothing }

        if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
            return cached
        }
        guard let compiled = try await store.compileContentRuleList(forIdentifier: identifier,
                                                                    encodedContentRuleList: json) else {
            throw BlockerError.compiledToNothing
        }
        // Drop lists compiled from earlier versions of the file.
        if let known = await store.availableIdentifiers() {
            for old in known where old.hasPrefix(identifierPrefix) && old != identifier {
                try? await store.removeContentRuleList(forIdentifier: old)
            }
        }
        return compiled
    }

    private static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
