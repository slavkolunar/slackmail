import Foundation

/// Izmišljene poruke za probni mejl i pregled dizajna (ne dira Slack).
enum SampleMail {
    static func items(selfID: String) -> [ForwardItem] {
        let now = Date().timeIntervalSince1970
        func msg(_ offset: Double, _ user: String, _ text: String, thread: String? = nil, files: [SlackMessage.SlackFile]? = nil) -> SlackMessage {
            let ts = String(format: "%.6f", now - offset)
            return SlackMessage(ts: ts, user: user, text: text, subtype: nil, thread_ts: thread.map { _ in String(format: "%.6f", now - 3600) },
                                reply_count: nil, latest_reply: nil, bot_id: nil, username: nil, bot_profile: nil, files: files, attachments: nil)
        }
        return [
            ForwardItem(message: msg(420, "U1", "<@\(selfID)> možeš li da pogledaš *deploy* za `payments-api`? Build pada na koraku _migrate_ :eyes:\n&gt; Error: relation \"invoices\" already exists"),
                        reasons: [.me], authorName: "Ana Petrović", authorAvatar: nil,
                        permalink: "https://slack.com/", threadParentText: nil),
            ForwardItem(message: msg(240, "U2", "<!here> u 15h kratak sync oko release-a. Agenda: <https://example.com/agenda|ovde> :rocket:"),
                        reasons: [.here], authorName: "Marko Jovanović", authorAvatar: nil,
                        permalink: "https://slack.com/", threadParentText: nil),
            ForwardItem(message: msg(60, "U3", "Evo loga sa servera:\n```2026-11-25 10:14:03 ERROR timeout after 30s\n2026-11-25 10:14:04 retrying (1/3)```",
                                     thread: "parent", files: [.init(name: "server.log", title: "server.log", pretty_type: "Text")]),
                        reasons: [.all], authorName: "Jelena Ilić", authorAvatar: nil,
                        permalink: "https://slack.com/", threadParentText: "Da li neko zna zašto je staging spor jutros?"),
        ]
    }

    static func make(team: String, selfID: String) -> ComposedMail {
        let names = ["U1": "Ana Petrović", "U2": "Marko Jovanović", "U3": "Jelena Ilić", selfID: "ti"]
        let composer = MailComposer(teamName: team,
                                    mrkdwn: Mrkdwn(selfID: selfID, userName: { names[$0] }, channelName: { _ in nil }))
        let rule = ChannelRule(id: "C0", name: "proba-slackmail", kind: .publicChannel, enabled: true)
        var mail = composer.compose(channel: rule, items: items(selfID: selfID))
        mail.subject = "[SlackMail] Probni mejl — ovako izgledaju prosleđene poruke"
        return mail
    }
}
