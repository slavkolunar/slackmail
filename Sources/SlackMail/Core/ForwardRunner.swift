import Foundation

/// Rezultat jednog ciklusa preko svih praćenih kanala.
struct CycleOutcome {
    var cursorUpdates: [String: String] = [:]
    var sent: [ActivityEntry] = []
    var errors: [String] = []
    var notes: [String] = []
    var retryAfter: Int?
    var nextStart = 0          // od kog kanala kreće sledeći ciklus (posle 429)
}

/// "Prikupi → pošalji → pomeri kursor" za sve kanale. Bez UI-ja i bez stanja, pa se testira bez mreže.
struct ForwardRunner {
    var client: SlackClient
    var transport: MailTransport
    var identity: SlackIdentity
    var directory: UserDirectory
    var from: String
    var fromName: String
    var recipients: [String]
    var channelNames: [String: String]

    func run(rules: [ChannelRule], cursors: [String: String], startAt: Int = 0, now: Date = Date(),
             isCancelled: () -> Bool = { false },
             onChannelDone: (String, String, ActivityEntry?) async -> Void = { _, _, _ in }) async -> CycleOutcome {
        var out = CycleOutcome()
        guard !rules.isEmpty else { return out }
        let processor = Processor(client: client, identity: identity, users: directory)
        let start = startAt % rules.count

        for step in 0..<rules.count {
            if isCancelled() { break }
            let index = (start + step) % rules.count
            let rule = rules[index]
            let place = MailComposer.placeName(rule)
            let cursor: String
            if let c = cursors[rule.id] {
                cursor = c
            } else {
                cursor = TS.from(now)                 // nepoznat kanal kreće od "sada"
                out.cursorUpdates[rule.id] = cursor
            }
            do {
                let batch = try await processor.collect(rule: rule, cursor: cursor, now: now)
                var entry: ActivityEntry?
                if !batch.items.isEmpty {
                    try await send(batch)
                    let first = batch.items[0]
                    entry = ActivityEntry(
                        date: Date(), channel: place, count: batch.items.count, ok: true,
                        detail: "\(first.authorName): \(MailComposer.snippet(Mrkdwn.unescapeSlack(first.message.text ?? ""), 80))")
                    out.sent.append(entry!)
                }
                // Kursor se pomera samo kada je mejl prihvaćen ili nije bilo šta da se šalje.
                out.cursorUpdates[rule.id] = batch.newCursor
                if batch.truncated {
                    out.notes.append("\(place): više od 1000 poruka za 48 h — najstarije u tom prozoru su preskočene")
                }
                await onChannelDone(rule.id, batch.newCursor, entry)
            } catch SlackError.rateLimited(let retry) {
                out.retryAfter = retry
                out.nextStart = index                // sledeći put krećemo baš od ovog kanala
                break
            } catch {
                // Greška jednog kanala ne zaustavlja ostale; kursor ostaje, pokušava se ponovo.
                out.errors.append("\(place): \(error.localizedDescription)")
            }
        }
        return out
    }

    private func send(_ batch: ChannelBatch) async throws {
        // Unapred učitamo imena pomenutih korisnika da bi mejl imao imena, ne ID-jeve.
        for item in batch.items {
            let texts = [item.message.text, item.threadParentText].compactMap { $0 }
            for id in texts.flatMap(AppModel.mentionedUserIDs) { _ = await directory.user(id) }
        }
        let names = await directory.snapshot()
        let composer = MailComposer(teamName: identity.team,
                                    mrkdwn: Mrkdwn(selfID: identity.userID, userName: { names[$0] },
                                                   channelName: { channelNames[$0] }))
        let mail = composer.compose(channel: batch.rule, items: batch.items, skippedOlder: batch.skippedOlder)
        let mime = MIME.build(from: from, fromName: fromName, to: recipients, mail: mail)
        try await transport.send(from: from, to: recipients, mime: mime)
    }
}
