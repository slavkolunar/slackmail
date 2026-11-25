import AppKit
import Foundation
import SwiftUI

/// `SlackMail --selftest` — proverava logiku bez mreže (lažni Slack i skriptovan SMTP).
enum SelfTest {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if cond { passed += 1 } else { failures += 1; print("✗ \(name) \(detail())") }
    }

    static func run() -> Bool {
        filterTests()
        mrkdwnTests()
        mimeTests()
        smtpParseTests()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await processorTests()
            await smtpDialogTests()
            await runnerTests()
            await timeoutTests()
            sem.signal()
        }
        sem.wait()
        print(failures == 0 ? "✓ selftest: svih \(passed) provera prošlo" : "✗ selftest: \(failures) palo, \(passed) prošlo")
        return failures == 0
    }

    static func m(_ ts: String, _ user: String?, _ text: String, subtype: String? = nil, thread: String? = nil,
                  replies: Int? = nil, latest: String? = nil) -> SlackMessage {
        SlackMessage(ts: ts, user: user, text: text, subtype: subtype, thread_ts: thread, reply_count: replies,
                     latest_reply: latest, bot_id: nil, username: nil, bot_profile: nil, files: nil, attachments: nil)
    }

    // MARK: Filter

    static func filterTests() {
        let me = "UME"
        var mentions = ChannelRule(id: "C1", name: "dev", kind: .publicChannel, enabled: true)
        mentions.mentionMe = true; mentions.mentionChannel = true; mentions.mentionHere = false
        var all = mentions; all.allMessages = true

        let cases: [(SlackMessage, ChannelRule, [MatchReason], String)] = [
            (m("1", "U1", "<@UME> pogledaj"), mentions, [.me], "pominje mene"),
            (m("1", "U1", "<@UME|marko> pogledaj"), mentions, [.me], "pominje mene sa labelom"),
            (m("1", "U1", "<@UMEX> nije ja"), mentions, [], "sličan ID nije ja"),
            (m("1", "U1", "<!channel> deploy"), mentions, [.channel], "@channel"),
            (m("1", "U1", "<!everyone> sastanak"), mentions, [.channel], "@everyone ide uz @channel"),
            (m("1", "U1", "<!here> brzo"), mentions, [], "@here isključen"),
            (m("1", "U1", "obična poruka"), mentions, [], "bez pominjanja"),
            (m("1", "U1", "obična poruka"), all, [.all], "sve poruke"),
            (m("1", "U1", "<@UME> hej"), all, [.me], "sve poruke + pominje mene"),
            (m("1", "UME", "<!channel> moja poruka"), all, [], "sopstvena poruka"),
            (m("1", "U1", "<@U1> je ušao", subtype: "channel_join"), all, [], "channel_join"),
            (m("1", "U1", "izmena", subtype: "message_changed"), all, [], "message_changed"),
            (m("1", nil, "Build failed", subtype: "bot_message"), all, [.all], "bot poruka prolazi"),
        ]
        for (msg, rule, expected, name) in cases {
            let got = MessageFilter.reasons(for: msg, rule: rule, selfID: me)
            check(got == expected, "filter: \(name)", "očekivano \(expected), dobijeno \(got)")
        }
        var here = mentions; here.mentionHere = true
        check(MessageFilter.reasons(for: m("1", "U1", "<!here> brzo"), rule: here, selfID: me) == [.here], "filter: @here uključen")
        var dm = ChannelRule(id: "D1", name: "Ana", kind: .directMessage, enabled: true); dm.allMessages = true
        check(MessageFilter.reasons(for: m("1", "U1", "ćao"), rule: dm, selfID: me) == [.direct], "filter: DM")
    }

    // MARK: Mrkdwn

    static func mrkdwnTests() {
        let md = Mrkdwn(selfID: "UME", userName: { ["U1": "Ana", "UME": "Marko"][$0] }, channelName: { $0 == "C9" ? "general" : nil })
        let xss = md.html("<script>alert(1)</script> &lt;b&gt;x&lt;/b&gt;")
        check(!xss.contains("<script>") && !xss.contains("<b>") && xss.contains("&lt;b&gt;"), "mrkdwn: HTML se escape-uje", xss)
        let mention = md.html("<@U1> i <@UME> u <#C9>")
        check(mention.contains("@Ana") && mention.contains("@Marko") && mention.contains("#general"), "mrkdwn: pominjanja", mention)
        check(mention.contains("#fff3c4"), "mrkdwn: moje pominjanje je istaknuto")
        let link = md.html("vidi <https://example.com/a?b=1&amp;c=2|agendu>")
        check(link.contains("href=\"https://example.com/a?b=1&amp;c=2\"") && link.contains(">agendu</a>"), "mrkdwn: link", link)
        let evil = md.html("<javascript:alert(1)|klikni>")
        check(!evil.contains("href"), "mrkdwn: javascript: nije link", evil)
        let fmt = md.html("*bold* _it_ ~s~ `kod` snake_case_name 2*3*4")
        check(fmt.contains("<strong>bold</strong>") && fmt.contains("<em>it</em>") && fmt.contains("<s>s</s>")
              && fmt.contains(">kod</code>") && fmt.contains("snake_case_name"), "mrkdwn: formatiranje", fmt)
        let code = md.html("pre ```*ne* <b>```posle")
        check(code.contains("<pre") && code.contains("*ne*") && !code.contains("<strong>ne"), "mrkdwn: blok koda", code)
        let quote = md.html("&gt; citat\nnormalno")
        check(quote.contains("border-left") && quote.contains("citat"), "mrkdwn: citat", quote)
        check(md.html(":rocket: :nepostoji:").contains("🚀") && md.html(":nepostoji:").contains(":nepostoji:"), "mrkdwn: emoji")
        check(md.plain("<@U1> &amp; <https://x.y|link> <!here>") == "@Ana & link (https://x.y) @here", "mrkdwn: običan tekst", md.plain("<@U1> &amp; <https://x.y|link> <!here>"))
        check(AppModel.mentionedUserIDs(in: "<@U1> i <@U2|ana>") == ["U1", "U2"], "mrkdwn: ID-jevi pominjanja")
    }

    // MARK: MIME

    static func mimeTests() {
        let mail = ComposedMail(subject: "Zdravo\r\nBcc: zlo@x.com 👋 ćčžšđ", html: "<p>ć</p>", text: "ć")
        let mime = MIME.build(from: "a@gmail.com", fromName: "SlackMail", to: ["b@x.com"], mail: mail)
        let headerPart = mime.components(separatedBy: "\r\n\r\n").first ?? ""
        check(!headerPart.contains("Bcc:"), "mime: nema ubacivanja zaglavlja", headerPart)
        check(headerPart.contains("Subject: =?utf-8?B?"), "mime: RFC 2047 naslov")
        check(mime.components(separatedBy: "\r\n").allSatisfy { $0.count <= 998 }, "mime: linije ≤ 998")
        let bodyLines = MIME.base64Lines(String(repeating: "x", count: 500)).components(separatedBy: "\r\n")
        check(bodyLines.allSatisfy { $0.count <= 76 }, "mime: base64 po 76")
        check(SMTPClient.dotStuff(".linija\nok\n..dve") == "..linija\r\nok\r\n...dve", "smtp: dot-stuffing")
        check(MailComposer.porukaPlural(1) == "nova poruka" && MailComposer.porukaPlural(3) == "nove poruke"
              && MailComposer.porukaPlural(5) == "novih poruka" && MailComposer.porukaPlural(12) == "novih poruka"
              && MailComposer.porukaPlural(21) == "nova poruka", "mejl: srpska množina")
        let link = Permalink.make(base: "https://acme.slack.com/", channel: "C1", message: m("1732.000100", "U1", "", thread: "1700.000001"))
        check(link == "https://acme.slack.com/archives/C1/p1732000100?thread_ts=1700.000001&cid=C1", "permalink niti", link)
    }

    // MARK: SMTP parsiranje

    static func smtpParseTests() {
        let multi = "250-smtp.gmail.com at your service\r\n250-SIZE 35882577\r\n250 SMTPUTF8\r\n"
        let r = SMTPClient.parseResponse(multi)
        check(r?.code == 250 && r?.consumed == multi.utf8.count, "smtp: višelinijski odgovor")
        check(SMTPClient.parseResponse("250-nepotpun\r\n") == nil, "smtp: nepotpun odgovor čeka")
    }

    // MARK: Processor (lažni Slack)

    final class FakeSlack: SlackClient, @unchecked Sendable {
        var failing: [String: Error] = [:]       // kanal → greška
        var perChannel: [String: [SlackMessage]] = [:]
        var historyMessages: [SlackMessage] = []
        var replyMessages: [String: [SlackMessage]] = [:]
        var repliesCalled: [String] = []
        func authTest() async throws -> SlackIdentity { SlackIdentity(userID: "UME", user: "ja", team: "Tim", teamID: "T1", url: "https://tim.slack.com/") }
        func conversations() async throws -> [SlackConversation] { [] }
        var truncate = false
        func history(channel: String, oldest: String) async throws -> (messages: [SlackMessage], truncated: Bool) {
            if let e = failing[channel] { throw e }
            if let list = perChannel[channel] { return (list.filter { TS.value($0.ts) > TS.value(oldest) }, truncate) }
            return (historyMessages.filter { TS.value($0.ts) > TS.value(oldest) }, truncate)
        }
        func replies(channel: String, threadTS: String, oldest: String) async throws -> [SlackMessage] {
            repliesCalled.append(threadTS)
            return (replyMessages[threadTS] ?? []).filter { TS.value($0.ts) > TS.value(oldest) }
        }
        func user(_ id: String) async throws -> SlackUser { SlackUser(id: id, displayName: "Korisnik \(id)", realName: "", avatarURL: nil) }
        func allUsers() async throws -> [SlackUser] { [] }
    }

    static func processorTests() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let t = { (ago: Double) in TS.from(now.addingTimeInterval(-ago)) }
        let fake = FakeSlack()
        let cursor = t(600)                      // poslednja obrada pre 10 min
        let oldParent = t(3600 * 30)             // nit od juče, sa novim odgovorom
        let quietParent = t(3600 * 5)            // nit bez novih odgovora
        fake.historyMessages = [
            m(t(900), "U1", "<@UME> staro, već obrađeno"),
            m(t(300), "U1", "<@UME> novo"),
            m(t(200), "UME", "<@UME> moja"),
            m(t(150), "U2", "obično"),
            m(t(100), "U2", "ušao", subtype: "channel_join"),
            m(oldParent, "U3", "pitanje <@UME>", thread: oldParent, replies: 3, latest: t(60)),
            m(quietParent, "U3", "tiha nit", thread: quietParent, replies: 1, latest: t(3600 * 4)),
        ]
        fake.replyMessages[oldParent] = [
            m(t(3600 * 29), "U4", "<@UME> stari odgovor", thread: oldParent),
            m(t(60), "U4", "<@UME> novi odgovor u niti", thread: oldParent),
        ]
        var rule = ChannelRule(id: "C1", name: "dev", kind: .publicChannel, enabled: true)
        rule.mentionMe = true
        let p = Processor(client: fake, identity: try! await fake.authTest(), users: UserDirectory(client: fake))
        do {
            let b = try await p.collect(rule: rule, cursor: cursor, now: now)
            let texts = b.items.map { $0.message.text ?? "" }
            check(texts == ["<@UME> novo", "<@UME> novi odgovor u niti"], "processor: nove poruke i odgovor u niti", "\(texts)")
            check(fake.repliesCalled == [oldParent], "processor: replies samo za promenjene niti", "\(fake.repliesCalled)")
            check(b.newCursor == t(60), "processor: kursor na najnoviju viđenu", b.newCursor)
            check(b.items.last?.threadParentText == "pitanje <@UME>", "processor: kontekst niti")
            check(b.items.first?.permalink.hasPrefix("https://tim.slack.com/archives/C1/p") == true, "processor: permalink")

            // Posle 3 dana odsustva: nadoknada najviše 24 h, ostalo se broji kao preskočeno.
            fake.historyMessages = [m(t(3600 * 40), "U1", "<@UME> pre 40h"), m(t(3600 * 2), "U1", "<@UME> pre 2h")]
            fake.repliesCalled = []
            let b2 = try await p.collect(rule: rule, cursor: t(3600 * 72), now: now)
            check(b2.items.map { $0.message.text ?? "" } == ["<@UME> pre 2h"], "processor: nadoknada ograničena na 24 h")
            check(b2.skippedOlder == 1, "processor: broji preskočene", "\(b2.skippedOlder)")

            // Bez novih poruka: kursor ostaje, ništa za slanje.
            fake.historyMessages = []
            let b3 = try await p.collect(rule: rule, cursor: cursor, now: now)
            check(b3.items.isEmpty && b3.newCursor == cursor, "processor: prazan ciklus")
        } catch {
            check(false, "processor: izuzetak", "\(error)")
        }
    }

    // MARK: SMTP dijalog (skriptovan server)

    final class ScriptedLink: SMTPLink {
        var responses: [String]
        var sent: [String] = []
        init(_ r: [String]) { responses = r }
        func open() async throws {}
        func send(_ s: String) async throws { sent.append(s) }
        func readResponse() async throws -> (code: Int, text: String) {
            guard !responses.isEmpty else { throw SMTPError.timeout }
            let r = SMTPClient.parseResponse(responses.removeFirst())!
            return (r.code, r.text)
        }
        func close() {}
    }

    static func smtpDialogTests() async {
        let ok = ScriptedLink(["220 ready\r\n", "250-hi\r\n250 AUTH PLAIN\r\n", "235 ok\r\n", "250 ok\r\n", "250 ok\r\n", "250 ok\r\n",
                               "354 go\r\n", "250 queued\r\n", "221 bye\r\n"])
        let client = SMTPClient(user: "a@gmail.com", password: "pw", link: { ok })
        do {
            try await client.send(from: "a@gmail.com", to: ["b@x.com", "c@x.com"], mime: "Subject: x\r\n\r\n.tačka")
            check(ok.sent.first == "EHLO slackmail.local\r\n", "smtp: EHLO")
            check(ok.sent.contains { $0.hasPrefix("AUTH PLAIN ") }, "smtp: AUTH PLAIN")
            check(ok.sent.filter { $0.hasPrefix("RCPT TO:") }.count == 2, "smtp: dva primaoca")
            check(ok.sent.contains { $0.hasSuffix("\r\n..tačka\r\n.\r\n") }, "smtp: telo sa dot-stuffing-om i završnom tačkom")
        } catch {
            check(false, "smtp: uspešan dijalog", "\(error)")
        }
        let bad = ScriptedLink(["220 ready\r\n", "250 hi\r\n", "535 5.7.8 Username and Password not accepted\r\n"])
        do {
            try await SMTPClient(user: "a@gmail.com", password: "x", link: { bad }).send(from: "a@gmail.com", to: ["b@x.com"], mime: "x")
            check(false, "smtp: 535 mora da baci grešku")
        } catch {
            check(error.localizedDescription.contains("535") && error.localizedDescription.contains("app password"),
                  "smtp: jasna poruka za 535", error.localizedDescription)
        }
    }
}

extension SelfTest {
    final class FakeTransport: MailTransport, @unchecked Sendable {
        var fail = false
        var sentSubjects: [String] = []
        func send(from: String, to: [String], mime: String) async throws {
            if fail { throw SMTPError.unexpected(step: "slanje", code: 421, text: "privremeno") }
            sentSubjects.append(mime)
        }
    }

    static func runnerTests() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let t = { (ago: Double) in TS.from(now.addingTimeInterval(-ago)) }
        let slack = FakeSlack()
        let mail = FakeTransport()
        func rule(_ id: String) -> ChannelRule {
            var r = ChannelRule(id: id, name: id.lowercased(), kind: .publicChannel, enabled: true)
            r.allMessages = true
            return r
        }
        slack.perChannel = ["CA": [m(t(30), "U1", "poruka A")], "CB": [m(t(20), "U2", "poruka B")]]
        slack.failing = ["CBAD": SlackError.api("channel_not_found")]
        let runner = ForwardRunner(client: slack, transport: mail, identity: try! await slack.authTest(),
                                   directory: UserDirectory(client: slack), from: "a@gmail.com", fromName: "SlackMail",
                                   recipients: ["b@x.com"], channelNames: [:])
        let cursors = ["CA": t(60), "CB": t(60), "CBAD": t(60)]

        // 1) Kanal koji pada ne blokira ostale; njegov kursor ostaje.
        // AppModel čuva stanje isključivo kroz onChannelDone, pa proveravamo i taj kanal.
        final class Calls: @unchecked Sendable { var list: [(String, String, Bool)] = [] }
        let calls = Calls()
        let record: (String, String, ActivityEntry?) async -> Void = { id, c, e in calls.list.append((id, c, e != nil)) }
        var out = await runner.run(rules: [rule("CBAD"), rule("CA"), rule("CB")], cursors: cursors, now: now,
                                   onChannelDone: record)
        check(calls.list.map(\.0) == ["CA", "CB"] && calls.list.map(\.1) == [t(30), t(20)] && calls.list.allSatisfy(\.2),
              "runner: onChannelDone posle slanja, ne za kanal sa greškom", "\(calls.list)")
        check(out.errors.count == 1 && out.errors[0].contains("channel_not_found"), "runner: greška jednog kanala", "\(out.errors)")
        check(out.sent.count == 2 && mail.sentSubjects.count == 2, "runner: ostali kanali obrađeni", "\(out.sent.count)")
        check(out.cursorUpdates["CBAD"] == nil, "runner: kursor kanala sa greškom ostaje")
        check(out.cursorUpdates["CA"] == t(30) && out.cursorUpdates["CB"] == t(20), "runner: kursori pomereni posle slanja")

        // 2) SMTP padne → kursor se ne pomera (poruka se šalje u sledećem ciklusu).
        mail.fail = true
        calls.list = []
        out = await runner.run(rules: [rule("CA")], cursors: cursors, now: now, onChannelDone: record)
        check(out.cursorUpdates["CA"] == nil && out.sent.isEmpty && out.errors.count == 1, "runner: SMTP greška čuva kursor")
        check(calls.list.isEmpty, "runner: onChannelDone se ne zove kad SMTP padne")
        mail.fail = false
        out = await runner.run(rules: [rule("CA")], cursors: cursors, now: now)
        check(out.cursorUpdates["CA"] == t(30) && out.sent.count == 1, "runner: ponovni pokušaj uspeva")

        // 3) 429 → prekid ciklusa, sledeći kreće od tog kanala.
        slack.failing = ["CB": SlackError.rateLimited(retryAfter: 42)]
        out = await runner.run(rules: [rule("CA"), rule("CB"), rule("CC")], cursors: cursors, now: now)
        check(out.retryAfter == 42 && out.nextStart == 1, "runner: 429 pamti gde je stao", "\(String(describing: out.retryAfter)) \(out.nextStart)")
        check(out.cursorUpdates["CC"] == nil, "runner: posle 429 ne ide dalje")

        // 4) Nepoznat kanal kreće od "sada" — bez slanja istorije.
        slack.failing = [:]
        out = await runner.run(rules: [rule("CNEW")], cursors: [:], now: now)
        check(out.cursorUpdates["CNEW"] != nil && out.sent.isEmpty, "runner: novi kanal kreće od sada")

        // 4b) Prazan kanal: callback sa nepromenjenim kursorom, bez unosa u aktivnost.
        calls.list = []
        slack.perChannel["CEMPTY"] = []
        _ = await runner.run(rules: [rule("CEMPTY")], cursors: ["CEMPTY": t(60)], now: now, onChannelDone: record)
        check(calls.list.count == 1 && calls.list[0].1 == t(60) && !calls.list[0].2, "runner: prazan kanal")

        // 4c) Dostignuta granica stranica → beleška.
        slack.truncate = true
        out = await runner.run(rules: [rule("CA")], cursors: cursors, now: now)
        check(out.notes.count == 1, "runner: beleška kad je istorija odsečena")
        slack.truncate = false

        // 5) Bot poruka sa praznim tekstom koristi attachments.
        var bot = m("1", nil, "", subtype: "bot_message")
        bot.attachments = [.init(fallback: "fb", pretext: "Deploy", title: "payments-api", text: "pao je build")]
        check(bot.withAttachmentText().text == "Deploy\n*payments-api*\npao je build", "bot: tekst iz attachments",
              bot.withAttachmentText().text ?? "")
        var onlyFallback = m("1", nil, "")
        onlyFallback.attachments = [.init(fallback: "samo fallback", pretext: nil, title: nil, text: nil)]
        check(onlyFallback.withAttachmentText().text == "samo fallback", "bot: fallback")
        check(m("1", "U1", "ima tekst").withAttachmentText().text == "ima tekst", "bot: postojeći tekst se ne dira")
    }

    static func timeoutTests() async {
        // op koji nikad ne završi (continuation bez nastavka) — withTimeout ipak mora da se vrati.
        final class Parked: @unchecked Sendable { var cont: CheckedContinuation<Int, Error>? }
        let parked = Parked()
        let t0 = Date()
        do {
            _ = try await withTimeout(0.3) {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in parked.cont = c }
            }
            check(false, "timeout: zaglavljen continuation mora da baci grešku")
        } catch {
            check(Date().timeIntervalSince(t0) < 2, "timeout: vraća se i kad op nikad ne završi")
        }
        parked.cont?.resume(returning: 0)   // pospremanje posle testa

        let cancelled = OnceFlag()
        let start = Date()
        do {
            _ = try await withTimeout(0.3, onTimeout: { _ = cancelled.claim() }) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
            check(false, "timeout: mora da baci grešku")
        } catch {
            check(Date().timeIntervalSince(start) < 2, "timeout: ne čeka zaglavljeni poziv")
            check(!cancelled.claim(), "timeout: poziva onTimeout (zatvaranje veze)")
        }
    }
}

/// Isto što i lista u ChannelsPane, ali bez LazyVStack-a (ImageRenderer ne crta lenje liste).
struct ChannelRowsPreview: View {
    var rules: [ChannelRule]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Kanali",
                       subtitle: "Čekiraj šta pratiš i za svaki kanal izaberi: sve poruke, ili samo kad si pomenut ti, @channel/@everyone ili @here.")
            VStack(spacing: 8) {
                ForEach(rules) { ChannelRow(rule: $0) { _ in } }
            }
        }
    }
}

/// `SlackMail --render <dir>` — PNG ikonica (1x/2x, svetla/tamna traka), popover i HTML uzorka mejla.
@MainActor
enum Render {
    static func run(outputDir: String) {
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Ikonice u stvarnoj veličini, na svetloj i tamnoj traci.
        for (bgName, bg, fg) in [("svetla", Color(white: 0.93), Color.black), ("tamna", Color(white: 0.16), Color.white)] {
            for scale in [1.0, 2.0] {
                let strip = HStack(spacing: 14) {
                    ForEach([MenuBarIcon.Variant.active, .paused, .error], id: \.self) { v in
                        Image(nsImage: MenuBarIcon.image(v)).renderingMode(.template).foregroundStyle(fg)
                    }
                    Image(systemName: "wifi").foregroundStyle(fg)
                    Image(systemName: "battery.75percent").foregroundStyle(fg)
                    Text("10:42").font(.system(size: 13)).foregroundStyle(fg)
                }
                .padding(.horizontal, 12).frame(height: 24).background(bg)
                write(strip, scale: scale, dir.appendingPathComponent("ikonica-\(bgName)-\(Int(scale))x.png"))
            }
        }
        write(AppGlyph(size: 512), scale: 1, dir.appendingPathComponent("app-ikonica.png"))

        // Iconset za .icns: logo 824×824 u platnu 1024 (macOS mreža ikonica), sve veličine.
        let iconset = dir.appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        let canvas = ZStack { AppGlyph(size: 824).shadow(color: .black.opacity(0.3), radius: 18, y: 10) }
            .frame(width: 1024, height: 1024)
        for base in [16, 32, 128, 256, 512] {
            for mult in [1, 2] {
                let name = mult == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                write(canvas, scale: CGFloat(base * mult) / 1024, iconset.appendingPathComponent(name))
            }
        }

        let model = AppModel(preview: true)
        for scheme in [ColorScheme.light, .dark] {
            let popover = MenuBarView().environmentObject(model).environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.97))
            write(popover, scale: 2, dir.appendingPathComponent("popover-\(scheme == .dark ? "tamna" : "svetla").png"))
        }
        // Paneli podešavanja sa izmišljenim kanalima.
        let demo = AppModel(preview: true)
        var r1 = ChannelRule(id: "C1", name: "backend", kind: .publicChannel, enabled: true)
        r1.mentionHere = true
        var r2 = ChannelRule(id: "C2", name: "incidenti", kind: .privateChannel, enabled: true)
        r2.allMessages = true
        var r3 = ChannelRule(id: "D1", name: "Ana Petrović", kind: .directMessage, enabled: true)
        r3.allMessages = true
        let r4 = ChannelRule(id: "C3", name: "random", kind: .publicChannel)
        let r5 = ChannelRule(id: "C4", name: "frontend", kind: .publicChannel)
        demo.settings.rules = [r1, r2, r3, r4, r5]
        demo.settings.recipients = ["ime@firma.com"]
        demo.settings.smtpUser = "ime@gmail.com"
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "tamna" : "svetla"
            let bg = scheme == .dark ? Color(white: 0.15) : Color(white: 0.98)
            write(VStack { ChannelRowsPreview(rules: demo.settings.rules) }.padding(24).frame(width: 760)
                    .environmentObject(demo).environment(\.colorScheme, scheme).background(bg),
                  scale: 1.5, dir.appendingPathComponent("kanali-\(suffix).png"))
            write(SlackPane().padding(24).frame(width: 760).environmentObject(demo)
                    .environment(\.colorScheme, scheme).background(bg),
                  scale: 1.5, dir.appendingPathComponent("slack-\(suffix).png"))
            write(GeneralPane().padding(24).frame(width: 760).environmentObject(demo)
                    .environment(\.colorScheme, scheme).background(bg),
                  scale: 1.5, dir.appendingPathComponent("opste-\(suffix).png"))
        }

        let mail = SampleMail.make(team: "Acme", selfID: "UME")
        try? mail.html.write(to: dir.appendingPathComponent("mejl-uzorak.html"), atomically: false, encoding: .utf8)
        print("✓ \(dir.path)")
    }

    private static func write<V: View>(_ view: V, scale: CGFloat, _ url: URL) {
        let r = ImageRenderer(content: view)
        r.scale = scale
        guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
