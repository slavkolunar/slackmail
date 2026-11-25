import Foundation

struct ChannelBatch {
    var rule: ChannelRule
    var items: [ForwardItem]
    var newCursor: String
    var skippedOlder: Int
    var truncated = false
}

/// Čista logika jednog ciklusa za jedan kanal: šta je novo, šta prolazi filter.
/// Ne šalje ništa i ne menja stanje — to radi pozivalac tek kad mejl prođe.
struct Processor {
    static let threadWindow: TimeInterval = 48 * 3600   // niti aktivne u poslednjih 48 h
    static let catchUpLimit: TimeInterval = 24 * 3600   // posle dužeg odsustva nadoknađuje najviše 24 h
    static let maxItemsPerMail = 30

    var client: SlackClient
    var identity: SlackIdentity
    var users: UserDirectory

    func collect(rule: ChannelRule, cursor: String, now: Date = Date()) async throws -> ChannelBatch {
        let floor = TS.from(now.addingTimeInterval(-Self.catchUpLimit))
        let effective = TS.max(cursor, floor)
        let windowStart = TS.from(now.addingTimeInterval(-Self.threadWindow))
        let oldest = TS.value(windowStart) < TS.value(effective) ? windowStart : effective

        let (history, truncated) = try await client.history(channel: rule.id, oldest: oldest)
        var candidates: [String: SlackMessage] = [:]
        var parents: [String: SlackMessage] = [:]
        var skipped = 0

        for m in history {
            if m.thread_ts == m.ts { parents[m.ts] = m }
            let v = TS.value(m.ts)
            if v > TS.value(effective) {
                candidates[m.ts] = m
            } else if v > TS.value(cursor) && !m.isThreadReply {
                skipped += 1   // starije od granice za nadoknadu
            }
        }

        // Niti u kojima ima novih odgovora od poslednje obrade.
        for parent in parents.values where (parent.reply_count ?? 0) > 0 && TS.value(parent.latest_reply) > TS.value(effective) {
            let replies = try await client.replies(channel: rule.id, threadTS: parent.ts, oldest: effective)
            for r in replies where r.ts != r.thread_ts && TS.value(r.ts) > TS.value(effective) {
                candidates[r.ts] = r
            }
        }

        let sorted = candidates.values.sorted { TS.value($0.ts) < TS.value($1.ts) }
        let newCursor = sorted.reduce(effective) { TS.max($0, $1.ts) }

        var items: [ForwardItem] = []
        for m in sorted {
            let reasons = MessageFilter.reasons(for: m, rule: rule, selfID: identity.userID)
            guard !reasons.isEmpty else { continue }
            let author = await users.author(of: m)
            items.append(ForwardItem(message: m, reasons: reasons, authorName: author.name,
                                     authorAvatar: author.avatar,
                                     permalink: Permalink.make(base: identity.url, channel: rule.id, message: m),
                                     threadParentText: m.thread_ts.flatMap { parents[$0]?.text }))
        }
        if items.count > Self.maxItemsPerMail {
            skipped += items.count - Self.maxItemsPerMail
            items = Array(items.suffix(Self.maxItemsPerMail))
        }
        return ChannelBatch(rule: rule, items: items, newCursor: newCursor, skippedOlder: skipped, truncated: truncated)
    }
}

/// Keš korisnika (ime, avatar). Thread-safe preko actor-a.
actor UserDirectory {
    private var cache: [String: SlackUser] = [:]
    private let client: SlackClient

    init(client: SlackClient, preload: [SlackUser] = []) {
        self.client = client
        for u in preload { cache[u.id] = u }
    }

    func name(_ id: String) -> String? { cache[id]?.name }

    func snapshot() -> [String: String] { cache.mapValues(\.name) }

    func user(_ id: String) async -> SlackUser? {
        if let u = cache[id] { return u }
        guard let u = try? await client.user(id) else { return nil }
        cache[id] = u
        return u
    }

    func author(of m: SlackMessage) async -> (name: String, avatar: String?) {
        if let id = m.user, let u = await user(id) { return (u.name, u.avatarURL) }
        if let bot = m.bot_profile?.name ?? m.username { return (bot, m.bot_profile?.icons?["image_72"]) }
        return (m.user ?? "Nepoznato", nil)
    }
}
