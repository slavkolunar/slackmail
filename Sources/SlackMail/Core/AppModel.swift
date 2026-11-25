import AppKit
import Combine
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement

enum EngineStatus: Equatable {
    case off, idle, checking, sending, error(String)

    var label: String {
        switch self {
        case .off: "Pauzirano"
        case .idle: "Aktivno — prati kanale"
        case .checking: "Proveravam Slack…"
        case .sending: "Šaljem mejl…"
        case .error(let e): e
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings { didSet { if settings != oldValue { settingsChanged(old: oldValue) } } }
    @Published private(set) var status: EngineStatus = .off
    @Published private(set) var identity: SlackIdentity?
    @Published private(set) var conversations: [SlackConversation] = []
    @Published private(set) var loadingChannels = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var keepingAwake = false
    @Published var slackToken: String {
        didSet {
            if !preview { Keychain.set(.slackToken, slackToken) }
            identity = nil
            userDirectory = nil          // drži klijent sa starim tokenom
        }
    }
    @Published var smtpPassword: String { didSet { if !preview { Keychain.set(.smtpPassword, smtpPassword) } } }
    @Published var testMessage: (ok: Bool, text: String)?

    private var state: ForwardState
    private var loop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var sleepAssertion: IOPMAssertionID = 0
    private var userDirectory: UserDirectory?
    private var userNames: [String: String] = [:]

    var forwardedToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return activity.filter { $0.ok && $0.date >= start }.map(\.count).reduce(0, +)
    }

    var enabledRules: [ChannelRule] { settings.rules.filter(\.enabled) }

    var isConfigured: Bool {
        !slackToken.isEmpty && !smtpPassword.isEmpty && !settings.smtpUser.isEmpty && !settings.recipients.isEmpty
    }

    private var checkRequested = false
    private var nextStartIndex = 0
    private let preview: Bool

    /// `preview: true` — prazan model bez Keychain-a, diska i petlje (za --render).
    init(preview: Bool = false) {
        self.preview = preview
        settings = preview ? AppSettings() : Storage.load(AppSettings.self, "settings.json") ?? AppSettings()
        state = preview ? ForwardState() : Storage.load(ForwardState.self, "state.json") ?? ForwardState()
        activity = preview ? [] : Storage.load([ActivityEntry].self, "activity.json") ?? []
        slackToken = preview ? "" : Keychain.get(.slackToken) ?? ""
        smtpPassword = preview ? "" : Keychain.get(.smtpPassword) ?? ""
        guard !preview else { return }

        // Posle buđenja odmah proverimo — nadoknada propuštenog.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkNow() }
        }
        // Posle restarta nastavljamo od sačuvanih kursora — ono što je stiglo u međuvremenu se nadoknađuje.
        if settings.forwardingEnabled { startLoop(resetCursors: false) }
    }

    /// Najmanji razmak između ciklusa: svaki kanal je bar jedan poziv istorije, a Slack dozvoljava ~50 u minuti.
    var effectiveInterval: Int {
        max(settings.pollSeconds, Int((Double(enabledRules.count) * 1.5).rounded(.up)), 15)
    }

    // MARK: - Uključivanje / isključivanje

    func setForwarding(_ on: Bool) {
        settings.forwardingEnabled = on
    }

    private func settingsChanged(old: AppSettings) {
        guard !preview else { return }
        Storage.save(settings, "settings.json")
        // Novouključen kanal kreće od "sada" — ne šaljemo istoriju.
        let oldEnabled = Set(old.rules.filter(\.enabled).map(\.id))
        for r in settings.rules where r.enabled && !oldEnabled.contains(r.id) {
            state.cursors[r.id] = TS.from(Date())
        }
        Storage.save(state, "state.json")
        if settings.forwardingEnabled != old.forwardingEnabled {
            // Ručno uključivanje: ne šaljemo ono što je stiglo dok je bilo pauzirano.
            settings.forwardingEnabled ? startLoop(resetCursors: true) : stopLoop()
        }
        updateSleepAssertion()
    }

    private func startLoop(resetCursors: Bool) {
        loop?.cancel()
        if resetCursors {
            for r in enabledRules { state.cursors[r.id] = TS.from(Date()) }
            Storage.save(state, "state.json")
        }
        status = .idle
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = await self?.cycle() else { return }
                // Čekamo u koracima od 1 s da bi "Proveri sada" i buđenje mogli da skrate čekanje,
                // a da nikad ne prekinu ciklus koji je u toku (npr. usred slanja mejla).
                let until = Date().addingTimeInterval(TimeInterval(wait))
                while Date() < until, !Task.isCancelled {
                    if self?.consumeCheckRequest() == true { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        updateSleepAssertion()
    }

    private func consumeCheckRequest() -> Bool {
        defer { checkRequested = false }
        return checkRequested
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
        status = .off
        updateSleepAssertion()
    }

    func checkNow() {
        guard settings.forwardingEnabled else { return }
        checkRequested = true
    }

    // MARK: - Ciklus

    /// Vraća koliko sekundi da sačeka do sledećeg ciklusa.
    private func cycle() async -> Int {
        guard settings.forwardingEnabled else { return settings.pollSeconds }
        guard isConfigured else {
            status = .error("Podešavanja nisu kompletna (token, Gmail, primalac)")
            return settings.pollSeconds
        }
        updateSleepAssertion()
        status = .checking
        let client = SlackWebClient(token: slackToken)
        let me: SlackIdentity
        do {
            me = try await ensureIdentity(client)
        } catch {
            if Task.isCancelled || !settings.forwardingEnabled { return effectiveInterval }
            fail(error.localizedDescription)
            return max(60, effectiveInterval)
        }
        let directory = await ensureDirectory(client)
        let runner = ForwardRunner(
            client: client,
            transport: SMTPClient(host: settings.smtpHost, port: settings.smtpPort,
                                  user: settings.smtpUser, password: smtpPassword),
            identity: me, directory: directory,
            from: settings.smtpUser, fromName: settings.senderName, recipients: settings.recipients,
            channelNames: Dictionary(settings.rules.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))

        let outcome = await runner.run(rules: enabledRules, cursors: state.cursors, startAt: nextStartIndex,
                                       isCancelled: { Task.isCancelled },
                                       onChannelDone: { [weak self] id, cursor, entry in
                                           self?.commit(channel: id, cursor: cursor, entry: entry)
                                       })
        nextStartIndex = outcome.nextStart
        for note in outcome.notes where activity.first?.detail != note {
            log(ActivityEntry(date: Date(), channel: "—", count: 0, ok: false, detail: note))
        }
        // Isključeno usred ciklusa: kursori su već sačuvani, status ne diramo (ostaje "Pauzirano").
        if Task.isCancelled || !settings.forwardingEnabled { return effectiveInterval }
        lastCheck = Date()

        if let retry = outcome.retryAfter {
            status = .error("Slack traži pauzu (\(retry) s)")
            return max(retry, effectiveInterval)
        }
        if let first = outcome.errors.first {
            fail(outcome.errors.count > 1 ? "\(first) (+\(outcome.errors.count - 1))" : first)
            return effectiveInterval
        }
        status = .idle
        return effectiveInterval
    }

    /// Čuva kursor odmah posle svakog kanala (gašenje usred ciklusa ne ponavlja već poslate mejlove).
    /// Kursor nikad ne ide unazad — stari ciklus ne sme da pregazi noviji reset.
    private func commit(channel id: String, cursor: String, entry: ActivityEntry?) {
        state.cursors[id] = TS.max(state.cursors[id] ?? cursor, cursor)
        Storage.save(state, "state.json")
        if let entry { log(entry) }
    }

    private func fail(_ msg: String) {
        status = .error(msg)
        if activity.first?.detail != msg {
            log(ActivityEntry(date: Date(), channel: "—", count: 0, ok: false, detail: msg))
        }
    }

    nonisolated static func mentionedUserIDs(in text: String) -> [String] {
        var ids: [String] = []
        var rest = Substring(text)
        while let r = rest.range(of: "<@") {
            let after = rest[r.upperBound...]
            let id = after.prefix { $0.isLetter || $0.isNumber }
            if !id.isEmpty { ids.append(String(id)) }
            rest = after
        }
        return ids
    }

    private func ensureIdentity(_ client: SlackClient) async throws -> SlackIdentity {
        if let identity { return identity }
        let me = try await client.authTest()
        identity = me
        return me
    }

    private func ensureDirectory(_ client: SlackClient) async -> UserDirectory {
        if let userDirectory { return userDirectory }
        let preload = (try? await client.allUsers()) ?? []
        let dir = UserDirectory(client: client, preload: preload)
        userDirectory = dir
        userNames = Dictionary(preload.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return dir
    }

    private func log(_ e: ActivityEntry) {
        activity.insert(e, at: 0)
        if activity.count > 200 { activity.removeLast(activity.count - 200) }
        if !preview { Storage.save(activity, "activity.json") }
    }

    // MARK: - Kanali

    func loadChannels() async {
        guard !slackToken.isEmpty else { return }
        loadingChannels = true
        defer { loadingChannels = false }
        let client = SlackWebClient(token: slackToken)
        do {
            _ = try await ensureIdentity(client)
            _ = await ensureDirectory(client)
            var list = try await client.conversations()
            for i in list.indices where list[i].kind == .directMessage {
                if let uid = list[i].dmUserID { list[i].name = userNames[uid] ?? uid }
            }
            for i in list.indices where list[i].kind == .groupMessage {
                // "mpdm-ana--marko--ja-1" → "ana, marko, ja"
                list[i].name = list[i].name.replacingOccurrences(of: "mpdm-", with: "")
                    .replacingOccurrences(of: "-1", with: "").replacingOccurrences(of: "--", with: ", ")
            }
            conversations = list
            mergeRules(with: list)
            testMessage = nil
        } catch {
            testMessage = (false, error.localizedDescription)
        }
    }

    private func mergeRules(with list: [SlackConversation]) {
        var byID = Dictionary(settings.rules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for c in list {
            if var r = byID[c.id] {
                r.name = c.name
                r.kind = c.kind
                byID[c.id] = r
            } else {
                var r = ChannelRule(id: c.id, name: c.name, kind: c.kind)
                if c.kind == .directMessage || c.kind == .groupMessage { r.allMessages = true }
                byID[c.id] = r
            }
        }
        settings.rules = byID.values.sorted {
            ($0.enabled ? 0 : 1, $0.kind.sortKey, $0.name.lowercased()) < ($1.enabled ? 0 : 1, $1.kind.sortKey, $1.name.lowercased())
        }
    }

    func updateRule(_ rule: ChannelRule) {
        guard let i = settings.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        settings.rules[i] = rule
    }

    // MARK: - Provere

    func testSlack() async {
        testMessage = nil
        identity = nil
        do {
            let me = try await ensureIdentity(SlackWebClient(token: slackToken))
            testMessage = (true, "Povezano kao @\(me.user) u timu \(me.team)")
            await loadChannels()
        } catch {
            testMessage = (false, error.localizedDescription)
        }
    }

    func sendTestMail() async {
        testMessage = nil
        do {
            guard !settings.recipients.isEmpty else { throw SMTPError.unexpected(step: "primalac", code: 0, text: "nije unet nijedan primalac") }
            let mail = SampleMail.make(team: identity?.team ?? "Tvoj tim", selfID: identity?.userID ?? "UME")
            let mime = MIME.build(from: settings.smtpUser, fromName: settings.senderName, to: settings.recipients, mail: mail)
            let transport = SMTPClient(host: settings.smtpHost, port: settings.smtpPort,
                                       user: settings.smtpUser, password: smtpPassword)
            try await transport.send(from: settings.smtpUser, to: settings.recipients, mime: mime)
            testMessage = (true, "Probni mejl je poslat na \(settings.recipients.joined(separator: ", "))")
        } catch {
            testMessage = (false, error.localizedDescription)
        }
    }

    // MARK: - Sprečavanje sleep-a

    private func updateSleepAssertion() {
        let want = settings.forwardingEnabled && settings.keepAwake && (!settings.keepAwakeOnlyOnAC || Power.onAC())
        if want && sleepAssertion == 0 {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "SlackMail prosleđuje Slack poruke na mejl" as CFString, &id)
            if r == kIOReturnSuccess { sleepAssertion = id }
        } else if !want && sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
        keepingAwake = sleepAssertion != 0
    }

    // MARK: - Pokretanje pri prijavi

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                testMessage = (false, "Pokretanje pri prijavi: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }
}

extension ConversationKind {
    var sortKey: Int {
        switch self {
        case .publicChannel: 0
        case .privateChannel: 1
        case .groupMessage: 2
        case .directMessage: 3
        }
    }
}

enum Power {
    static func onAC() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        return type == kIOPSACPowerValue
    }
}
