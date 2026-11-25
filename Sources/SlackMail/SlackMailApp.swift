import AppKit
import SwiftUI

@main
struct Launcher {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            MainActor.assumeIsolated { Render.run(outputDir: args[i + 1]) }
            return
        }
        SlackMailApp.main()
    }
}

struct SlackMailApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            Image(nsImage: MenuBarIcon.image(iconVariant))
        }
        .menuBarExtraStyle(.window)

        Window("SlackMail — podešavanja", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(.contentMinSize)
        // Prozor se otvara tek na klik u meniju; pri pokretanju samo dok podešavanje nije završeno.
        .defaultLaunchBehavior(Self.needsSetup ? .presented : .suppressed)
        .restorationBehavior(.disabled)
    }

    /// Čita se jednom pri pokretanju (bez AppModel-a, koji tada još nije spreman).
    static let needsSetup: Bool = {
        let s = Storage.load(AppSettings.self, "settings.json") ?? AppSettings()
        return Keychain.get(.slackToken) == nil || Keychain.get(.smtpPassword) == nil
            || s.smtpUser.isEmpty || s.recipients.isEmpty || !s.rules.contains(where: \.enabled)
    }()

    private var iconVariant: MenuBarIcon.Variant {
        switch model.status {
        case .off: .paused
        case .error: .error
        default: .active
        }
    }
}
