import Foundation

enum SlackError: LocalizedError {
    case api(String)
    case http(Int)
    case rateLimited(retryAfter: Int)
    case noToken

    var errorDescription: String? {
        switch self {
        case .api(let code): "Slack greška: \(code)\(Self.hint(code))"
        case .http(let code): "Slack HTTP \(code)"
        case .rateLimited(let s): "Slack ograničenje brzine — ponovo za \(s) s"
        case .noToken: "Slack token nije unet"
        }
    }

    private static func hint(_ code: String) -> String {
        switch code {
        case "invalid_auth", "not_authed": " (token nije ispravan)"
        case "token_revoked", "account_inactive": " (token je opozvan — napravi novi)"
        case "missing_scope": " (Slack app nema potrebna prava — proveri manifest i reinstaliraj)"
        case "channel_not_found": " (kanal ne postoji ili nisi član)"
        default: ""
        }
    }
}

/// Sve što aplikacija traži od Slack-a. Protokol omogućava testiranje bez mreže.
protocol SlackClient: Sendable {
    func authTest() async throws -> SlackIdentity
    func conversations() async throws -> [SlackConversation]
    /// Najnovije prvo (Slack). `truncated` = bilo je još poruka posle granice stranica.
    func history(channel: String, oldest: String) async throws -> (messages: [SlackMessage], truncated: Bool)
    func replies(channel: String, threadTS: String, oldest: String) async throws -> [SlackMessage]
    func user(_ id: String) async throws -> SlackUser
    func allUsers() async throws -> [SlackUser]
}

struct SlackWebClient: SlackClient {
    var token: String
    var session: URLSession = .shared

    fileprivate func call(_ method: String, _ params: [String: String]) async throws -> [String: Any] {
        guard !token.isEmpty else { throw SlackError.noToken }
        var comps = URLComponents(string: "https://slack.com/api/\(method)")!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30
                throw SlackError.rateLimited(retryAfter: retry)
            }
            guard (200..<300).contains(http.statusCode) else { throw SlackError.http(http.statusCode) }
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackError.api("invalid_json")
        }
        guard json["ok"] as? Bool == true else { throw SlackError.api(json["error"] as? String ?? "unknown") }
        return json
    }

    /// Svaka poruka se dekodira posebno — jedna neobična poruka ne sme da obori ceo kanal.
    private func decodeMessages(_ any: Any?) throws -> [SlackMessage] {
        guard let arr = any as? [Any] else { return [] }
        let decoder = JSONDecoder()
        return arr.compactMap { item in
            guard let data = try? JSONSerialization.data(withJSONObject: item),
                  let m = try? decoder.decode(SlackMessage.self, from: data) else { return nil }
            return m.withAttachmentText()
        }
    }

    func authTest() async throws -> SlackIdentity {
        let j = try await call("auth.test", [:])
        return SlackIdentity(userID: j["user_id"] as? String ?? "", user: j["user"] as? String ?? "",
                             team: j["team"] as? String ?? "", teamID: j["team_id"] as? String ?? "",
                             url: j["url"] as? String ?? "https://slack.com/")
    }

    func conversations() async throws -> [SlackConversation] {
        var result: [SlackConversation] = []
        var cursor = ""
        repeat {
            var p = ["types": "public_channel,private_channel,mpim,im", "exclude_archived": "true", "limit": "200"]
            if !cursor.isEmpty { p["cursor"] = cursor }
            let j = try await call("users.conversations", p)
            for c in j["channels"] as? [[String: Any]] ?? [] {
                guard let id = c["id"] as? String else { continue }
                let kind: ConversationKind =
                    c["is_im"] as? Bool == true ? .directMessage :
                    c["is_mpim"] as? Bool == true ? .groupMessage :
                    c["is_private"] as? Bool == true ? .privateChannel : .publicChannel
                result.append(SlackConversation(id: id, name: c["name"] as? String ?? id, kind: kind,
                                                isMember: true, dmUserID: c["user"] as? String))
            }
            cursor = (j["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
        } while !cursor.isEmpty
        return result
    }

    func history(channel: String, oldest: String) async throws -> (messages: [SlackMessage], truncated: Bool) {
        var all: [SlackMessage] = []
        var cursor = ""
        var pages = 0
        repeat {
            var p = ["channel": channel, "oldest": oldest, "limit": "200", "inclusive": "false"]
            if !cursor.isEmpty { p["cursor"] = cursor }
            let j = try await call("conversations.history", p)
            all += try decodeMessages(j["messages"])
            cursor = (j["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
            pages += 1
        } while !cursor.isEmpty && pages < 5
        return (all, !cursor.isEmpty)
    }

    func replies(channel: String, threadTS: String, oldest: String) async throws -> [SlackMessage] {
        let j = try await call("conversations.replies",
                               ["channel": channel, "ts": threadTS, "oldest": oldest, "limit": "200", "inclusive": "false"])
        return try decodeMessages(j["messages"])
    }

    func user(_ id: String) async throws -> SlackUser {
        let j = try await call("users.info", ["user": id])
        let u = j["user"] as? [String: Any] ?? [:]
        let profile = u["profile"] as? [String: Any] ?? [:]
        return SlackUser(id: id,
                         displayName: profile["display_name"] as? String ?? "",
                         realName: profile["real_name"] as? String ?? (u["real_name"] as? String ?? ""),
                         avatarURL: profile["image_72"] as? String)
    }
}

extension SlackWebClient {
    func allUsers() async throws -> [SlackUser] {
        var result: [SlackUser] = []
        var cursor = ""
        var pages = 0
        repeat {
            var p = ["limit": "500"]
            if !cursor.isEmpty { p["cursor"] = cursor }
            let j = try await call("users.list", p)
            for u in j["members"] as? [[String: Any]] ?? [] {
                guard let id = u["id"] as? String else { continue }
                let profile = u["profile"] as? [String: Any] ?? [:]
                result.append(SlackUser(id: id, displayName: profile["display_name"] as? String ?? "",
                                        realName: profile["real_name"] as? String ?? (u["real_name"] as? String ?? ""),
                                        avatarURL: profile["image_72"] as? String))
            }
            cursor = (j["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
            pages += 1
        } while !cursor.isEmpty && pages < 40
        return result
    }
}

enum Permalink {
    /// https://tim.slack.com/archives/C123/p1732531200123456[?thread_ts=…&cid=…]
    static func make(base: String, channel: String, message: SlackMessage) -> String {
        let root = base.hasSuffix("/") ? base : base + "/"
        let p = "p" + message.ts.replacingOccurrences(of: ".", with: "")
        var link = "\(root)archives/\(channel)/\(p)"
        if message.isThreadReply, let t = message.thread_ts { link += "?thread_ts=\(t)&cid=\(channel)" }
        return link
    }
}
