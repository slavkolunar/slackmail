import Foundation

struct ComposedMail {
    var subject: String
    var html: String
    var text: String
}

/// Pravi jedan mejl za jedan kanal i jedan ciklus (više poruka = jedan mejl).
struct MailComposer {
    var teamName: String
    var mrkdwn: Mrkdwn

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "sr_Latn")
        f.dateFormat = "d. MMM, HH:mm"
        return f
    }()

    func compose(channel: ChannelRule, items: [ForwardItem], skippedOlder: Int = 0) -> ComposedMail {
        let place = Self.placeName(channel)
        let mentionsMe = items.contains { $0.reasons.contains(.me) }
        let count = items.count
        var subject = "[Slack] \(place)"
        if count == 1, let first = items.first {
            subject += " — \(first.authorName): \(Self.snippet(mrkdwn.plain(first.message.text ?? ""), 60))"
        } else {
            subject += " — \(count) \(Self.porukaPlural(count))"
        }
        if mentionsMe { subject = "👋 " + subject }

        return ComposedMail(subject: Self.headerSafe(subject),
                            html: html(channel: channel, place: place, items: items, skippedOlder: skippedOlder),
                            text: text(place: place, items: items))
    }

    // MARK: - HTML (tabele + inline CSS zbog mejl klijenata)

    private func html(channel: ChannelRule, place: String, items: [ForwardItem], skippedOlder: Int) -> String {
        let esc = Mrkdwn.escapeHTML
        let headline = items.count == 1 ? "Nova poruka" : "\(items.count) \(Self.porukaPlural(items.count))"
        let firstLink = items.first?.permalink ?? ""
        var cards = ""
        for item in items {
            cards += card(item)
        }
        let skippedNote = skippedOlder > 0
            ? "<p style=\"margin:0 0 12px;font-size:12px;color:#8a8a8f;\">+ \(skippedOlder) starijih poruka nije prosleđeno (laptop je bio isključen duže od 24 h).</p>"
            : ""

        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light"><title>\(esc(place))</title></head>
        <body style="margin:0;padding:0;background:#f4f2f7;">
        <div style="display:none;max-height:0;overflow:hidden;">\(esc(Self.snippet(mrkdwn.plain(items.first?.message.text ?? ""), 110)))</div>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f2f7;">
        <tr><td align="center" style="padding:28px 12px;">
        <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
          <tr><td style="background:#4a154b;background-image:linear-gradient(135deg,#3b0f3c 0%,#611f69 55%,#8c3a7a 100%);border-radius:14px 14px 0 0;padding:22px 26px;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
              <td style="vertical-align:middle;">
                <div style="font-size:12px;letter-spacing:1px;text-transform:uppercase;color:#e9d7ea;font-weight:600;">\(esc(teamName)) · Slack</div>
                <div style="font-size:24px;font-weight:700;color:#ffffff;margin-top:4px;">\(esc(place))</div>
                <div style="font-size:13px;color:#e9d7ea;margin-top:4px;">\(esc(headline)) · \(esc(channel.kind.label.lowercased()))</div>
              </td>
              <td align="right" style="vertical-align:middle;">
                <div style="width:46px;height:46px;border-radius:12px;background:rgba(255,255,255,0.16);color:#ffffff;font-size:24px;line-height:46px;text-align:center;font-weight:700;">\(channel.kind == .directMessage || channel.kind == .groupMessage ? "@" : "#")</div>
              </td>
            </tr></table>
          </td></tr>
          <tr><td style="background:#ffffff;padding:22px 26px 8px;border-left:1px solid #e8e4ec;border-right:1px solid #e8e4ec;">
            \(skippedNote)
            \(cards)
          </td></tr>
          <tr><td style="background:#ffffff;padding:6px 26px 26px;border:1px solid #e8e4ec;border-top:0;border-radius:0 0 14px 14px;" align="center">
            <a href="\(esc(firstLink))" style="display:inline-block;background:#4a154b;color:#ffffff;text-decoration:none;font-weight:600;font-size:14px;padding:12px 26px;border-radius:8px;">Otvori u Slack-u</a>
          </td></tr>
          <tr><td align="center" style="padding:16px 10px;font-size:11px;color:#8a8a8f;line-height:1.6;">
            Prosleđeno aplikacijom <strong>SlackMail</strong> sa tvog Mac-a.<br>
            Kanale i pravila menjaš klikom na ikonicu u gornjoj traci → Podešavanja.
          </td></tr>
        </table>
        </td></tr></table>
        </body></html>
        """
    }

    private func card(_ item: ForwardItem) -> String {
        let esc = Mrkdwn.escapeHTML
        let time = Self.timeFormat.string(from: item.message.date)
        let initials = String(item.authorName.prefix(1)).uppercased()
        let avatar: String
        if let url = item.authorAvatar {
            avatar = "<img src=\"\(esc(url))\" width=\"40\" height=\"40\" alt=\"\(esc(initials))\" style=\"display:block;border-radius:8px;\">"
        } else {
            avatar = "<div style=\"width:40px;height:40px;border-radius:8px;background:#e8d9ea;color:#4a154b;font-weight:700;font-size:16px;line-height:40px;text-align:center;\">\(esc(initials))</div>"
        }
        let badges = item.reasons.map { r -> String in
            let (bg, fg) = r == .me ? ("#fff3c4", "#8a5a00") : r == .all || r == .direct ? ("#eef0f3", "#55565a") : ("#fdf0d5", "#8a5a00")
            return "<span style=\"display:inline-block;background:\(bg);color:\(fg);font-size:11px;font-weight:600;border-radius:10px;padding:2px 8px;margin-left:6px;\">\(esc(r.rawValue))</span>"
        }.joined()
        var thread = ""
        if item.message.isThreadReply {
            let parent = item.threadParentText.map { "„\(esc(Self.snippet(mrkdwn.plain($0), 90)))“" } ?? ""
            thread = "<div style=\"font-size:12px;color:#8a8a8f;margin:2px 0 6px;\">↳ odgovor u niti \(parent)</div>"
        }
        var files = ""
        for f in item.message.files ?? [] {
            let name = f.title ?? f.name ?? "fajl"
            files += "<div style=\"display:inline-block;margin:8px 6px 0 0;border:1px solid #e3e3e8;border-radius:8px;padding:6px 10px;font-size:12px;color:#1d1c1d;\">📎 \(esc(name))<span style=\"color:#8a8a8f;\"> · \(esc(f.pretty_type ?? "fajl"))</span></div>"
        }
        let body = mrkdwn.html(item.message.text ?? "")
        return """
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:16px;border:1px solid #efedf2;border-radius:10px;">
          <tr>
            <td width="56" style="vertical-align:top;padding:14px 0 14px 14px;">\(avatar)</td>
            <td style="vertical-align:top;padding:12px 14px 14px 10px;">
              <div style="font-size:15px;color:#1d1c1d;"><strong>\(esc(item.authorName))</strong>
                <span style="font-size:12px;color:#8a8a8f;margin-left:6px;">\(esc(time))</span>\(badges)</div>
              \(thread)
              <div style="font-size:15px;line-height:1.5;color:#1d1c1d;margin-top:4px;word-wrap:break-word;">\(body)</div>
              \(files)
              <div style="margin-top:8px;"><a href="\(esc(item.permalink))" style="font-size:12px;color:#1264a3;text-decoration:none;">Prikaži u Slack-u →</a></div>
            </td>
          </tr>
        </table>
        """
    }

    // MARK: - Običan tekst

    private func text(place: String, items: [ForwardItem]) -> String {
        var lines = ["\(teamName) · Slack · \(place)", ""]
        for item in items {
            let reasons = item.reasons.map(\.rawValue).joined(separator: ", ")
            lines.append("\(item.authorName) — \(Self.timeFormat.string(from: item.message.date)) [\(reasons)]")
            if item.message.isThreadReply { lines.append("(odgovor u niti)") }
            lines.append(mrkdwn.plain(item.message.text ?? ""))
            for f in item.message.files ?? [] { lines.append("📎 \(f.title ?? f.name ?? "fajl")") }
            lines.append(item.permalink)
            lines.append("")
        }
        lines.append("— Prosleđeno aplikacijom SlackMail")
        return lines.joined(separator: "\n")
    }

    // MARK: - Pomoćno

    static func placeName(_ c: ChannelRule) -> String {
        switch c.kind {
        case .publicChannel, .privateChannel: "#" + c.name
        case .directMessage, .groupMessage: c.name
        }
    }

    static func porukaPlural(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "nova poruka" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "nove poruke" }
        return "novih poruka"
    }

    static func snippet(_ s: String, _ max: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    /// Bez CR/LF u zaglavljima (zaštita od ubacivanja zaglavlja).
    static func headerSafe(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ")
    }
}

// MARK: - MIME

enum MIME {
    static func build(from: String, fromName: String, to: [String], mail: ComposedMail,
                      date: Date = Date(), boundary: String = "SM-" + UUID().uuidString) -> String {
        let domain = from.split(separator: "@").last.map(String.init) ?? "localhost"
        let headers = [
            "From: \(encodeWord(fromName)) <\(MailComposer.headerSafe(from))>",
            "To: " + to.map { "<\(MailComposer.headerSafe($0))>" }.joined(separator: ", "),
            "Subject: \(encodeWord(mail.subject))",
            "Date: \(rfc2822(date))",
            "Message-ID: <\(UUID().uuidString)@\(domain)>",
            "MIME-Version: 1.0",
            "X-Mailer: SlackMail",
            "Content-Type: multipart/alternative; boundary=\"\(boundary)\"",
        ]
        let parts = [
            "--\(boundary)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            base64Lines(mail.text),
            "--\(boundary)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            base64Lines(mail.html),
            "--\(boundary)--",
            "",
        ]
        return (headers + [""] + parts).joined(separator: "\r\n")
    }

    /// RFC 2047: =?utf-8?B?…?= u delovima, da nijedna linija zaglavlja ne bude preduga.
    static func encodeWord(_ s: String) -> String {
        let safe = MailComposer.headerSafe(s)
        if safe.allSatisfy({ $0.isASCII && $0 != "=" && $0 != "?" }) && safe.count < 70 { return safe }
        var chunks: [String] = []
        var current = ""
        for ch in safe {
            if (current + String(ch)).utf8.count > 42 {
                chunks.append(current)
                current = ""
            }
            current.append(ch)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.map { "=?utf-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    static func base64Lines(_ s: String) -> String {
        Data(s.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    static func rfc2822(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: d)
    }
}
