import SwiftUI

enum Brand {
    static let aubergine = Color(red: 0.29, green: 0.08, blue: 0.29)
    static let plum = Color(red: 0.38, green: 0.12, blue: 0.41)
    static let rose = Color(red: 0.55, green: 0.23, blue: 0.48)
    static let good = Color(red: 0.18, green: 0.72, blue: 0.45)
    static let warning = Color(red: 0.96, green: 0.66, blue: 0.16)
    static let critical = Color(red: 0.92, green: 0.30, blue: 0.30)
    static let gradient = LinearGradient(colors: [aubergine, plum, rose], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            header
            if !model.isConfigured {
                setupCard
            } else {
                toggleCard
                stats
            }
            if case .error(let msg) = model.status {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.critical)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Brand.critical.opacity(0.1)))
            }
            recent
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("SlackMail").font(.system(size: 15, weight: .bold, design: .rounded))
                HStack(spacing: 5) {
                    PulseDot(color: statusColor, pulsing: model.status == .idle || model.status == .checking)
                    Text(model.status.label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let id = model.identity {
                Text("@\(id.user)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .off: .secondary
        case .idle, .checking, .sending: Brand.good
        case .error: Brand.critical
        }
    }

    private var toggleCard: some View {
        HStack(spacing: 12) {
            Image(systemName: model.settings.forwardingEnabled ? "paperplane.fill" : "paperplane")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(
                    model.settings.forwardingEnabled ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.secondary.opacity(0.5))))
                .symbolEffect(.bounce, value: model.settings.forwardingEnabled)
            VStack(alignment: .leading, spacing: 2) {
                Text("Prosleđivanje na mejl").font(.system(size: 13, weight: .semibold))
                Text(model.settings.forwardingEnabled
                     ? "\(model.enabledRules.count) \(model.enabledRules.count == 1 ? "kanal" : "kanala") → \(model.settings.recipients.first ?? "")"
                     : "Isključeno — ništa se ne šalje")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.settings.forwardingEnabled }, set: { model.setForwarding($0) }))
                .toggleStyle(.switch).labelsHidden()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Podešavanje nije završeno", systemImage: "wand.and.stars").font(.system(size: 13, weight: .semibold))
            SetupStep(done: !model.slackToken.isEmpty, text: "Slack token")
            SetupStep(done: !model.enabledRules.isEmpty, text: "Bar jedan praćen kanal")
            SetupStep(done: !model.settings.smtpUser.isEmpty && !model.smtpPassword.isEmpty, text: "Gmail nalog i app password")
            SetupStep(done: !model.settings.recipients.isEmpty, text: "Adresa primaoca")
            Button {
                openSettings()
            } label: {
                Text("Završi podešavanje").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Brand.plum).controlSize(.large)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private var stats: some View {
        HStack(spacing: 8) {
            StatBox(value: "\(model.forwardedToday)", label: "danas prosleđeno")
            StatBox(value: "\(model.enabledRules.count)", label: "praćenih kanala")
            StatBox(value: model.lastCheck.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—", label: "poslednja provera")
        }
        .safeAreaInset(edge: .bottom) {
            if model.keepingAwake {
                Label("Mac ostaje budan dok je prosleđivanje uključeno", systemImage: "cup.and.saucer.fill")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Poslednje aktivnosti").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if model.activity.isEmpty {
                Text("Još ništa nije prosleđeno.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ForEach(model.activity.prefix(4)) { e in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: e.ok ? "envelope.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(e.ok ? Brand.plum : Brand.critical)
                        .frame(width: 14).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(e.ok ? "\(e.channel) · \(e.count)" : "Greška").font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Text(e.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Text(e.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Button {
                openSettings()
            } label: { Label("Podešavanja…", systemImage: "gearshape") }
            Spacer()
            Button {
                model.checkNow()
            } label: { Label("Proveri sada", systemImage: "arrow.clockwise") }
                .disabled(!model.settings.forwardingEnabled)
            Button {
                NSApp.terminate(nil)
            } label: { Image(systemName: "power") }
                .help("Zatvori SlackMail")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SetupStep: View {
    var done: Bool
    var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Brand.good : .secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(done ? .secondary : .primary)
                .strikethrough(done, color: .secondary)
        }
    }
}

struct StatBox: View {
    var value: String
    var label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct PulseDot: View {
    var color: Color
    var pulsing: Bool
    @State private var animate = false
    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(color.opacity(0.4)).scaleEffect(animate ? 2.4 : 1).opacity(animate ? 0 : 1)
            }
            Circle().fill(color)
        }
        .frame(width: 7, height: 7)
        .onAppear {
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { animate = true }
        }
    }
}

/// Logo u boji (za popover, prozor i ikonicu aplikacije).
struct AppGlyph: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Brand.gradient)
            Image(nsImage: MenuBarIcon.image(.active, scale: max(1, size / 16)))
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white)
                .padding(size * 0.2)
        }
        .frame(width: size, height: size)
    }
}
