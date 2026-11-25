import AppKit
import SwiftUI
import WebKit

enum SettingsPage: String, CaseIterable, Identifiable {
    case slack, channels, mail, general, activity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .slack: "Slack nalog"
        case .channels: "Kanali"
        case .mail: "Mejl"
        case .general: "Opšte"
        case .activity: "Aktivnost"
        }
    }
    var symbol: String {
        switch self {
        case .slack: "number.square"
        case .channels: "list.bullet.rectangle"
        case .mail: "envelope"
        case .general: "gearshape"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var page: SettingsPage? = .slack

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    AppGlyph(size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("SlackMail").font(.system(size: 14, weight: .bold, design: .rounded))
                        Text(model.status.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 10)
                List(selection: $page) {
                    ForEach(SettingsPage.allCases) { p in
                        Label(p.title, systemImage: p.symbol).tag(p)
                    }
                }
                .listStyle(.sidebar)
                MasterSwitch().padding(10)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
        } detail: {
            ScrollView {
                Group {
                    switch page ?? .slack {
                    case .slack: SlackPane()
                    case .channels: ChannelsPane()
                    case .mail: MailPane()
                    case .general: GeneralPane()
                    case .activity: ActivityPane()
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle((page ?? .slack).title)
        }
        .frame(minWidth: 860, minHeight: 600)
    }
}

// MARK: - Zajedničko

struct PaneHeader: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold, design: .rounded))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }
}

struct Panel<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct ResultBanner: View {
    var result: (ok: Bool, text: String)?
    var body: some View {
        if let result {
            Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 12))
                .foregroundStyle(result.ok ? Brand.good : Brand.critical)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill((result.ok ? Brand.good : Brand.critical).opacity(0.1)))
                .textSelection(.enabled)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

struct MasterSwitch: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Prosleđivanje").font(.system(size: 12, weight: .semibold))
                Text(model.settings.forwardingEnabled ? "uključeno" : "isključeno")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.settings.forwardingEnabled }, set: { model.setForwarding($0) }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(!model.isConfigured && !model.settings.forwardingEnabled)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(model.settings.forwardingEnabled ? Brand.good.opacity(0.12) : Color.primary.opacity(0.05)))
        .help(model.isConfigured ? "" : "Prvo unesi Slack token, Gmail podatke i primaoca")
    }
}

// MARK: - Slack

struct SlackPane: View {
    @EnvironmentObject var model: AppModel
    @State private var tokenDraft = ""
    @State private var working = false
    @State private var showManifest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "Slack nalog",
                       subtitle: "SlackMail čita poruke preko tvog sopstvenog Slack app-a i vidi tačno ono što vidiš i ti. Token se čuva samo u macOS Keychain-u.")

            Panel(title: "1. Napravi Slack app (jednom)") {
                VStack(alignment: .leading, spacing: 6) {
                    Step(n: 1, text: "Otvori api.slack.com/apps → Create New App → From a manifest")
                    Step(n: 2, text: "Izaberi workspace i nalepi manifest (dugme ispod ga kopira)")
                    Step(n: 3, text: "Install to Workspace → Allow (možda traži odobrenje admina)")
                    Step(n: 4, text: "OAuth & Permissions → kopiraj User OAuth Token (xoxp-…)")
                }
                HStack {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://api.slack.com/apps?new_app=1")!)
                    } label: { Label("Otvori api.slack.com", systemImage: "safari") }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SlackManifest.yaml, forType: .string)
                        withAnimation { showManifest = true }
                    } label: { Label("Kopiraj manifest", systemImage: "doc.on.doc") }
                    if showManifest { Text("Kopirano ✓").font(.system(size: 11)).foregroundStyle(Brand.good) }
                }
            }

            Panel(title: "2. Unesi token") {
                HStack {
                    SecureField("xoxp-…", text: $tokenDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button("Sačuvaj") {
                        model.slackToken = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        tokenDraft = ""
                        Task { working = true; await model.testSlack(); working = false }
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !tokenDraft.isEmpty && !tokenDraft.hasPrefix("xoxp-") {
                    Text("User token počinje sa „xoxp-“. Bot token (xoxb-) ne vidi tvoja pominjanja.")
                        .font(.system(size: 11)).foregroundStyle(Brand.warning)
                }
                HStack {
                    Image(systemName: model.slackToken.isEmpty ? "key" : "key.fill")
                        .foregroundStyle(model.slackToken.isEmpty ? Color.secondary : Brand.good)
                    Text(model.slackToken.isEmpty ? "Token nije sačuvan" : "Token je sačuvan u Keychain-u (…\(String(model.slackToken.suffix(4))))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Proveri vezu") { Task { working = true; await model.testSlack(); working = false } }
                        .disabled(model.slackToken.isEmpty || working)
                    if !model.slackToken.isEmpty {
                        Button("Ukloni", role: .destructive) { model.slackToken = "" }
                    }
                }
                ResultBanner(result: model.testMessage)
            }

            if let id = model.identity {
                Panel(title: nil) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 26)).foregroundStyle(Brand.good)
                        VStack(alignment: .leading) {
                            Text("@\(id.user)").font(.system(size: 15, weight: .semibold))
                            Text("\(id.team) · \(id.url)").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .animation(.default, value: model.testMessage?.text)
    }
}

private struct Step: View {
    var n: Int
    var text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(Brand.plum))
            Text(text).font(.system(size: 12))
        }
    }
}

// MARK: - Kanali

struct ChannelsPane: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var filter = 0   // 0 svi, 1 praćeni, 2 kanali, 3 direktne

    private var rules: [ChannelRule] {
        model.settings.rules.filter { r in
            let f: Bool = switch filter {
            case 1: r.enabled
            case 2: r.kind == .publicChannel || r.kind == .privateChannel
            case 3: r.kind == .directMessage || r.kind == .groupMessage
            default: true
            }
            return f && (search.isEmpty || r.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Kanali",
                       subtitle: "Čekiraj šta pratiš i za svaki kanal izaberi: sve poruke, ili samo kad si pomenut ti, @channel/@everyone ili @here. Pominjanja u nitima se takođe hvataju.")
            HStack {
                TextField("Pretraži kanale i osobe", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Picker("", selection: $filter) {
                    Text("Svi").tag(0)
                    Text("Praćeni (\(model.enabledRules.count))").tag(1)
                    Text("Kanali").tag(2)
                    Text("Direktne").tag(3)
                }
                .pickerStyle(.segmented).labelsHidden()
                Spacer()
                if model.loadingChannels { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.loadChannels() }
                } label: { Label("Osveži listu", systemImage: "arrow.clockwise") }
                    .disabled(model.slackToken.isEmpty)
            }
            if model.settings.rules.isEmpty {
                Panel(title: nil) {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.tertiary)
                        Text(model.slackToken.isEmpty ? "Prvo unesi Slack token." : "Klikni „Osveži listu“ da učitaš kanale.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(20)
                }
            }
            LazyVStack(spacing: 8) {
                ForEach(rules) { rule in
                    ChannelRow(rule: rule) { model.updateRule($0) }
                }
            }
        }
        .task { if model.settings.rules.isEmpty && !model.slackToken.isEmpty { await model.loadChannels() } }
    }
}

struct ChannelRow: View {
    var rule: ChannelRule
    var onChange: (ChannelRule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle("", isOn: bind(\.enabled)).toggleStyle(.checkbox).labelsHidden()
                Image(systemName: rule.kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(rule.enabled ? .white : .secondary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(rule.enabled ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.06))))
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.name).font(.system(size: 13, weight: .medium))
                    Text(rule.kind.label).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if rule.enabled {
                    Text(rule.summary).font(.system(size: 11, weight: .medium)).foregroundStyle(Brand.plum)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Brand.plum.opacity(0.1)))
                }
            }
            if rule.enabled {
                HStack(spacing: 8) {
                    Picker("", selection: bind(\.allMessages)) {
                        Text("Sve poruke").tag(true)
                        Text("Samo pominjanja").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                    if !rule.allMessages {
                        ChipToggle(title: "@ja", isOn: bind(\.mentionMe))
                        ChipToggle(title: "@channel / @everyone", isOn: bind(\.mentionChannel))
                        ChipToggle(title: "@here", isOn: bind(\.mentionHere))
                    }
                }
                .padding(.leading, 62)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(rule.enabled ? Brand.plum.opacity(0.06) : Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(rule.enabled ? Brand.plum.opacity(0.25) : Color.primary.opacity(0.06)))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: rule)
    }

    private func bind(_ kp: WritableKeyPath<ChannelRule, Bool>) -> Binding<Bool> {
        Binding(get: { rule[keyPath: kp] }, set: { v in var r = rule; r[keyPath: kp] = v; onChange(r) })
    }
}

struct ChipToggle: View {
    var title: String
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark" : "plus").font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(isOn ? .white : .primary)
            .background(Capsule().fill(isOn ? AnyShapeStyle(Brand.plum) : AnyShapeStyle(Color.primary.opacity(0.07))))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mejl

struct MailPane: View {
    @EnvironmentObject var model: AppModel
    @State private var passwordDraft = ""
    @State private var recipientsText = ""
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "Mejl",
                       subtitle: "Poruke iz jednog kanala u jednom ciklusu stižu kao jedan mejl. Šalje se preko tvog Gmail naloga (SMTP, app password).")

            Panel(title: "Primaoci") {
                TextField("ime@firma.com, drugi@primer.com", text: $recipientsText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveRecipients)
                    .onChange(of: recipientsText) { _, _ in saveRecipients() }
                Text(recipientsHint).font(.system(size: 11)).foregroundStyle(invalidRecipients.isEmpty ? Color.secondary : Brand.warning)
            }

            Panel(title: "Pošiljalac — Gmail") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Gmail adresa").foregroundStyle(.secondary)
                        TextField("ti@gmail.com", text: Binding(get: { model.settings.smtpUser },
                                                                set: { model.settings.smtpUser = $0.trimmingCharacters(in: .whitespaces) }))
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("App password").foregroundStyle(.secondary)
                        HStack {
                            SecureField(model.smtpPassword.isEmpty ? "16 slova iz Google naloga" : "•••• sačuvano u Keychain-u", text: $passwordDraft)
                                .textFieldStyle(.roundedBorder)
                            Button("Sačuvaj") {
                                model.smtpPassword = passwordDraft.replacingOccurrences(of: " ", with: "")
                                passwordDraft = ""
                            }
                            .disabled(passwordDraft.isEmpty)
                        }
                    }
                    GridRow {
                        Text("Ime pošiljaoca").foregroundStyle(.secondary)
                        TextField("SlackMail", text: $model.settings.senderName).textFieldStyle(.roundedBorder)
                    }
                }
                .font(.system(size: 12))
                HStack {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://myaccount.google.com/apppasswords")!)
                    } label: { Label("Napravi app password", systemImage: "key.viewfinder") }
                    Spacer()
                    if sending { ProgressView().controlSize(.small) }
                    Button {
                        Task { sending = true; await model.sendTestMail(); sending = false }
                    } label: { Label("Pošalji probni mejl", systemImage: "paperplane") }
                        .buttonStyle(.borderedProminent).tint(Brand.plum)
                        .disabled(sending || model.settings.smtpUser.isEmpty || model.smtpPassword.isEmpty || model.settings.recipients.isEmpty)
                }
                ResultBanner(result: model.testMessage)
            }

            Panel(title: "Pregled dizajna") {
                MailPreview(html: SampleMail.make(team: model.identity?.team ?? "Tvoj tim",
                                                  selfID: model.identity?.userID ?? "UME").html)
                    .frame(height: 620)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .onAppear { recipientsText = model.settings.recipients.joined(separator: ", ") }
        .animation(.default, value: model.testMessage?.text)
    }

    private var parsed: [String] {
        recipientsText.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var invalidRecipients: [String] {
        parsed.filter { !$0.contains("@") || !$0.contains(".") || $0.contains("<") || $0.contains(">") }
    }

    private var recipientsHint: String {
        if !invalidRecipients.isEmpty { return "Neispravno: \(invalidRecipients.joined(separator: ", "))" }
        return parsed.isEmpty ? "Unesi bar jednu adresu; više adresa odvoji zarezom." : "\(parsed.count) \(parsed.count == 1 ? "primalac" : "primaoca")"
    }

    private func saveRecipients() {
        let valid = parsed.filter { !invalidRecipients.contains($0) }
        if valid != model.settings.recipients { model.settings.recipients = valid }
    }
}

struct MailPreview: NSViewRepresentable {
    var html: String
    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.setValue(false, forKey: "drawsBackground")
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {
        v.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: - Opšte

struct GeneralPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "Opšte", subtitle: "Koliko često se proverava Slack i kako se Mac ponaša dok je prosleđivanje uključeno.")

            Panel(title: "Provera") {
                HStack {
                    Text("Proveravaj Slack na svakih")
                    Picker("", selection: $model.settings.pollSeconds) {
                        Text("30 s").tag(30)
                        Text("1 min").tag(60)
                        Text("2 min").tag(120)
                        Text("5 min").tag(300)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
                .font(.system(size: 12))
                Text("Kraći interval = brže stižu mejlovi; Slack dozvoljava ovaj tempo za sopstvene app-ove.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Panel(title: "Napajanje i sleep") {
                Toggle("Drži Mac budnim dok je prosleđivanje uključeno", isOn: $model.settings.keepAwake)
                Toggle("Samo kada je na struji", isOn: $model.settings.keepAwakeOnlyOnAC)
                    .disabled(!model.settings.keepAwake).padding(.leading, 20)
                Label("Ekran sme da se ugasi. Zatvaranje poklopca ipak uspavljuje laptop (osim uz spoljni monitor) — tada se ništa ne prosleđuje, a po buđenju se nadoknađuje do 24 h propuštenog.",
                      systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.keepingAwake {
                    Label("Trenutno: Mac se drži budnim", systemImage: "cup.and.saucer.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Brand.good)
                }
            }
            .font(.system(size: 12))

            Panel(title: "Pokretanje") {
                Toggle("Pokreni SlackMail pri prijavi na Mac", isOn: Binding(get: { model.launchAtLogin },
                                                                            set: { model.launchAtLogin = $0 }))
                    .font(.system(size: 12))
                Text("Najbolje radi kad je aplikacija premeštena u folder Applications.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Aktivnost

struct ActivityPane: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Aktivnost", subtitle: "Poslednjih 200 prosleđivanja i grešaka (čuva se samo lokalno).")
            if model.activity.isEmpty {
                Text("Još nema aktivnosti.").foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 6) {
                ForEach(model.activity) { e in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: e.ok ? "envelope.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(e.ok ? Brand.plum : Brand.critical).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.ok ? "\(e.channel) — \(e.count) \(MailComposer.porukaPlural(e.count))" : "Greška")
                                .font(.system(size: 12, weight: .semibold))
                            Text(e.detail).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                }
            }
        }
    }
}

enum SlackManifest {
    static let yaml = """
    display_information:
      name: SlackMail
      description: Prosleđuje odabrane Slack poruke na mejl dok nisi za računarom.
      background_color: "#4a154b"
    oauth_config:
      scopes:
        user:
          - channels:read
          - channels:history
          - groups:read
          - groups:history
          - im:read
          - im:history
          - mpim:read
          - mpim:history
          - users:read
    settings:
      org_deploy_enabled: false
      socket_mode_enabled: false
      token_rotation_enabled: false
    """
}
