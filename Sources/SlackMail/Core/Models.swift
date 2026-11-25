import Foundation

// MARK: - Podešavanja (bez tajni — tajne su u Keychain-u)

/// Šta u kanalu pokreće prosleđivanje.
struct ChannelRule: Codable, Hashable, Identifiable {
    var id: String               // Slack ID kanala (C…, G…, D…)
    var name: String
    var kind: ConversationKind
    var enabled: Bool = false
    var allMessages: Bool = false   // sve poruke
    var mentionMe: Bool = true      // @ja
    var mentionChannel: Bool = true // @channel / @everyone
    var mentionHere: Bool = false   // @here

    var summary: String {
        if allMessages { return "Sve poruke" }
        let parts = [mentionMe ? "@ja" : nil, mentionChannel ? "@channel" : nil, mentionHere ? "@here" : nil]
            .compactMap { $0 }
        return parts.isEmpty ? "Ništa" : parts.joined(separator: " · ")
    }
}

enum ConversationKind: String, Codable, Hashable {
    case publicChannel, privateChannel, directMessage, groupMessage

    var symbol: String {
        switch self {
        case .publicChannel: "number"
        case .privateChannel: "lock"
        case .directMessage: "person"
        case .groupMessage: "person.2"
        }
    }
    var label: String {
        switch self {
        case .publicChannel: "Javni kanal"
        case .privateChannel: "Privatni kanal"
        case .directMessage: "Direktna poruka"
        case .groupMessage: "Grupna poruka"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var forwardingEnabled = false
    var pollSeconds: Int = 60
    var keepAwake = true
    var keepAwakeOnlyOnAC = true
    var recipients: [String] = []
    var smtpUser = ""              // Gmail adresa (ujedno pošiljalac)
    var smtpHost = "smtp.gmail.com"
    var smtpPort: Int = 465
    var senderName = "SlackMail"
    var rules: [ChannelRule] = []
}

/// Stanje koje mora da preživi restart: dokle je koji kanal obrađen.
struct ForwardState: Codable {
    var cursors: [String: String] = [:]   // id kanala → ts poslednje obrađene poruke
}

// MARK: - Slack modeli

struct SlackIdentity: Equatable {
    var userID: String
    var user: String
    var team: String
    var teamID: String
    var url: String          // npr. https://acme.slack.com/
}

struct SlackConversation: Identifiable, Hashable {
    var id: String
    var name: String
    var kind: ConversationKind
    var isMember: Bool
    var dmUserID: String?
}

struct SlackMessage: Codable, Hashable {
    var ts: String
    var user: String?
    var text: String?
    var subtype: String?
    var thread_ts: String?
    var reply_count: Int?
    var latest_reply: String?
    var bot_id: String?
    var username: String?
    var bot_profile: BotProfile?
    var files: [SlackFile]?
    var attachments: [Attachment]?

    struct Attachment: Codable, Hashable {
        var fallback: String?
        var pretext: String?
        var title: String?
        var text: String?
    }

    /// Integracije (GitHub, Jira, alarmi) često šalju prazan `text`, a sadržaj je u `attachments`.
    func withAttachmentText() -> SlackMessage {
        guard (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let atts = attachments, !atts.isEmpty
        else { return self }
        var copy = self
        copy.text = atts.map { a -> String in
            let parts = [a.pretext, a.title.map { "*\($0)*" }, a.text].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? (a.fallback ?? "") : parts.joined(separator: "\n")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
        return copy
    }

    struct BotProfile: Codable, Hashable {
        var name: String?
        var icons: [String: String]?
    }
    struct SlackFile: Codable, Hashable {
        var name: String?
        var title: String?
        var pretty_type: String?
    }

    var isThreadReply: Bool { thread_ts != nil && thread_ts != ts }
    var date: Date { Date(timeIntervalSince1970: Double(ts) ?? 0) }
}

struct SlackUser: Hashable {
    var id: String
    var displayName: String
    var realName: String
    var avatarURL: String?
    var name: String { displayName.isEmpty ? (realName.isEmpty ? id : realName) : displayName }
}

// MARK: - Rezultat obrade

enum MatchReason: String, Codable, Hashable, CaseIterable {
    case me = "pominje tebe"
    case channel = "@channel"
    case here = "@here"
    case all = "nova poruka"
    case direct = "direktna poruka"
}

struct ForwardItem: Hashable {
    var message: SlackMessage
    var reasons: [MatchReason]
    var authorName: String
    var authorAvatar: String?
    var permalink: String
    var threadParentText: String?
}

struct ActivityEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var channel: String
    var count: Int
    var ok: Bool
    var detail: String
}

/// Slack ts ("1732531200.123456") ↔ Double; poređenje kao brojeva, ne stringova.
enum TS {
    static func value(_ ts: String?) -> Double { Double(ts ?? "") ?? 0 }
    static func from(_ date: Date) -> String { String(format: "%.6f", date.timeIntervalSince1970) }
    static func max(_ a: String, _ b: String) -> String { value(a) >= value(b) ? a : b }
}
