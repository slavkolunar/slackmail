import Foundation

enum MessageFilter {
    /// Podtipovi koji nisu "prave" poruke (ulazak/izlazak, izmene, teme kanala…).
    static let ignoredSubtypes: Set<String> = [
        "channel_join", "channel_leave", "group_join", "group_leave", "channel_topic", "channel_purpose",
        "channel_name", "group_topic", "group_purpose", "group_name", "message_changed", "message_deleted",
        "message_replied", "pinned_item", "unpinned_item", "channel_archive", "channel_unarchive",
        "group_archive", "group_unarchive", "reminder_add", "huddle_thread", "sh_room_created",
        "bot_add", "bot_remove", "joiner_notification_for_inviter", "tombstone",
    ]

    /// Razlozi zbog kojih poruka ide na mejl; prazno = ne prosleđuje se.
    static func reasons(for m: SlackMessage, rule: ChannelRule, selfID: String) -> [MatchReason] {
        if let st = m.subtype, ignoredSubtypes.contains(st) { return [] }
        if m.user == selfID { return [] }                 // sopstvene poruke
        let text = m.text ?? ""
        var r: [MatchReason] = []
        let mentionsMe = text.contains("<@\(selfID)>") || text.contains("<@\(selfID)|")
        let mentionsChannel = text.contains("<!channel") || text.contains("<!everyone")
        let mentionsHere = text.contains("<!here")

        if rule.mentionMe && mentionsMe { r.append(.me) }
        if rule.mentionChannel && mentionsChannel { r.append(.channel) }
        if rule.mentionHere && mentionsHere { r.append(.here) }
        if rule.allMessages && r.isEmpty {
            r.append(rule.kind == .directMessage || rule.kind == .groupMessage ? .direct : .all)
        }
        // U režimu "sve poruke" i dalje istaknemo pominjanje, čak i ako ga korisnik nije posebno čekirao.
        if rule.allMessages, mentionsMe, !r.contains(.me) { r.insert(.me, at: 0) }
        return r
    }
}

/// Slack "mrkdwn" → HTML i običan tekst. Ulaz je nepouzdan: sve se escape-uje.
struct Mrkdwn {
    var selfID: String
    var userName: (String) -> String?     // U123 → ime
    var channelName: (String) -> String?  // C123 → ime

    static func escapeHTML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Slack u tekstu već escape-uje &, <, > — vraćamo ih u sirov oblik pre našeg escape-a.
    static func unescapeSlack(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private enum Piece {
        case text(String)
        case token(String)   // sadržaj između < i >
    }

    private func pieces(_ s: String) -> [Piece] {
        var result: [Piece] = []
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            if open > rest.startIndex { result.append(.text(String(rest[rest.startIndex..<open]))) }
            result.append(.token(String(rest[rest.index(after: open)..<close])))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { result.append(.text(String(rest))) }
        return result
    }

    /// Token → (tekst, opcioni link, vrsta) — za HTML i za običan tekst.
    private func resolve(_ rawToken: String) -> (text: String, href: String?, mention: MentionStyle?) {
        let token = Self.unescapeSlack(rawToken)   // Slack escape-uje & i u URL-ovima
        let parts = token.split(separator: "|", maxSplits: 1).map(String.init)
        let head = parts.first ?? ""
        let label = parts.count > 1 ? parts[1] : nil
        if head.hasPrefix("@") {
            let id = String(head.dropFirst())
            let name = userName(id) ?? label ?? id
            return ("@" + name, nil, id == selfID ? .me : .user)
        }
        if head.hasPrefix("#") {
            let id = String(head.dropFirst())
            return ("#" + (channelName(id) ?? label ?? id), nil, .user)
        }
        if head.hasPrefix("!") {
            let cmd = String(head.dropFirst())
            if cmd == "here" || cmd == "channel" || cmd == "everyone" { return ("@" + cmd, nil, .broadcast) }
            if cmd.hasPrefix("subteam^") { return (label ?? "@grupa", nil, .user) }
            if cmd.hasPrefix("date^") { return (label ?? "", nil, nil) }
            return (label ?? cmd, nil, nil)
        }
        if head.hasPrefix("mailto:") { return (label ?? String(head.dropFirst(7)), head, nil) }
        if head.hasPrefix("http://") || head.hasPrefix("https://") { return (label ?? head, head, nil) }
        return (label ?? head, nil, nil)
    }

    enum MentionStyle { case me, user, broadcast }

    // MARK: Običan tekst

    func plain(_ raw: String) -> String {
        pieces(raw).map { p -> String in
            switch p {
            case .text(let t): Self.unescapeSlack(t)
            case .token(let tok): plainToken(tok)
            }
        }.joined()
    }

    private func plainToken(_ tok: String) -> String {
        let r = resolve(tok)
        if let href = r.href, href != r.text, !href.hasPrefix("mailto:") { return "\(r.text) (\(href))" }
        return r.text
    }

    // MARK: HTML

    func html(_ raw: String) -> String {
        // Blokovi koda (```) ne dobijaju formatiranje.
        let segments = raw.components(separatedBy: "```")
        var out = ""
        for (i, seg) in segments.enumerated() {
            if i % 2 == 1 && i < segments.count - 1 {
                let code = Self.escapeHTML(plain(seg).trimmingCharacters(in: .newlines))
                out += "<pre style=\"background:#f6f6f8;border:1px solid #e3e3e8;border-radius:6px;padding:10px 12px;"
                    + "font-family:SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;line-height:1.5;"
                    + "white-space:pre-wrap;margin:6px 0;color:#1d1c1d;\">\(code)</pre>"
            } else {
                out += inline(i % 2 == 1 ? "```" + seg : seg)
            }
        }
        return out
    }

    private func inline(_ raw: String) -> String {
        // Citati: linije koje počinju sa "&gt; " u Slack tekstu.
        let lines = raw.components(separatedBy: "\n")
        var html: [String] = []
        for line in lines {
            if line.hasPrefix("&gt; ") || line == "&gt;" {
                let body = line.hasPrefix("&gt; ") ? String(line.dropFirst(5)) : ""
                html.append("<div style=\"border-left:3px solid #dddddd;padding-left:10px;color:#616061;\">\(inlineLine(body))</div>")
            } else {
                html.append(inlineLine(line) + "<br>")
            }
        }
        var s = html.joined()
        if s.hasSuffix("<br>") { s.removeLast(4) }
        return s.replacingOccurrences(of: "</div><br>", with: "</div>")
    }

    private func inlineLine(_ raw: String) -> String {
        pieces(raw).map { p -> String in
            switch p {
            case .text(let t): return Self.formatText(Self.escapeHTML(Self.unescapeSlack(Emoji.replace(t))))
            case .token(let tok):
                let r = resolve(tok)
                let text = Self.escapeHTML(r.text)
                if let href = r.href {
                    return "<a href=\"\(Self.escapeHTML(href))\" style=\"color:#1264a3;text-decoration:none;\">\(text)</a>"
                }
                switch r.mention {
                case .me:
                    return "<span style=\"background:#fff3c4;color:#8a5a00;border-radius:4px;padding:0 3px;font-weight:600;\">\(text)</span>"
                case .broadcast:
                    return "<span style=\"background:#fdf0d5;color:#8a5a00;border-radius:4px;padding:0 3px;font-weight:600;\">\(text)</span>"
                case .user:
                    return "<span style=\"background:#e8f2fb;color:#1264a3;border-radius:4px;padding:0 3px;\">\(text)</span>"
                case nil:
                    return text
                }
            }
        }.joined()
    }

    /// *podebljano*, _kurziv_, ~precrtano~, `kod` — nad već escape-ovanim tekstom.
    static func formatText(_ s: String) -> String {
        var out = s
        out = wrap(out, "`", "<code style=\"background:#f6f6f8;border:1px solid #e3e3e8;border-radius:4px;padding:0 4px;font-family:SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;color:#c01343;\">", "</code>")
        out = wrap(out, "*", "<strong>", "</strong>")
        out = wrap(out, "_", "<em>", "</em>")
        out = wrap(out, "~", "<s>", "</s>")
        return out
    }

    /// Menja parove markera na granicama reči; ne dira markere unutar reči (npr. snake_case).
    private static func wrap(_ s: String, _ marker: Character, _ open: String, _ close: String) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let prevOK = i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber)
            if c == marker, prevOK, i + 1 < chars.count, chars[i + 1] != " ", chars[i + 1] != marker {
                // traži zatvarajući marker u istoj liniji
                var j = i + 1
                var found = -1
                while j < chars.count {
                    if chars[j] == marker, chars[j - 1] != " ",
                       j + 1 == chars.count || !(chars[j + 1].isLetter || chars[j + 1].isNumber) {
                        found = j
                        break
                    }
                    j += 1
                }
                if found > i + 1 {
                    out += open + String(chars[(i + 1)..<found]) + close
                    i = found + 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }
}

/// Najčešći Slack emoji kodovi → Unicode.
enum Emoji {
    static let map: [String: String] = [
        "smile": "😄", "slightly_smiling_face": "🙂", "grinning": "😀", "joy": "😂", "wink": "😉", "thinking_face": "🤔",
        "+1": "👍", "thumbsup": "👍", "-1": "👎", "thumbsdown": "👎", "clap": "👏", "pray": "🙏", "raised_hands": "🙌",
        "white_check_mark": "✅", "heavy_check_mark": "✔️", "x": "❌", "warning": "⚠️", "rotating_light": "🚨",
        "fire": "🔥", "rocket": "🚀", "tada": "🎉", "eyes": "👀", "heart": "❤️", "100": "💯", "point_up": "☝️",
        "point_right": "👉", "wave": "👋", "ok_hand": "👌", "muscle": "💪", "sweat_smile": "😅", "sob": "😭",
        "bug": "🐛", "memo": "📝", "calendar": "📅", "hourglass": "⌛", "red_circle": "🔴", "large_green_circle": "🟢",
        "zap": "⚡", "bulb": "💡", "lock": "🔒", "coffee": "☕", "beers": "🍻", "star": "⭐", "question": "❓",
        "exclamation": "❗", "heavy_plus_sign": "➕", "see_no_evil": "🙈", "partying_face": "🥳", "facepalm": "🤦",
    ]

    static func replace(_ s: String) -> String {
        guard s.contains(":") else { return s }
        var out = ""
        var rest = Substring(s)
        while let a = rest.firstIndex(of: ":") {
            let after = rest.index(after: a)
            guard let b = rest[after...].firstIndex(of: ":") else { break }
            let code = String(rest[after..<b])
            if let e = map[code] {
                out += rest[rest.startIndex..<a] + e
                rest = rest[rest.index(after: b)...]
            } else {
                out += rest[rest.startIndex..<after]
                rest = rest[after...]
            }
        }
        return out + rest
    }
}
