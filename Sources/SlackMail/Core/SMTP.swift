import Foundation
import Network

enum SMTPError: LocalizedError {
    case connection(String)
    case timeout
    case unexpected(step: String, code: Int, text: String)
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .connection(let s): "SMTP veza: \(s)"
        case .timeout: "SMTP server nije odgovorio na vreme"
        case .missingCredentials: "Gmail adresa ili app password nisu uneti"
        case .unexpected(let step, let code, let text):
            "SMTP \(step): \(code) \(text)\(Self.hint(code, text))"
        }
    }

    private static func hint(_ code: Int, _ text: String) -> String {
        if code == 535 { return " — pogrešna adresa ili app password (obična Gmail lozinka ne radi)" }
        if code == 534 { return " — Google traži app password (uključi dvostepenu potvrdu)" }
        if code == 550 || code == 553 { return " — server odbija adresu" }
        if code == 421 || code == 454 { return " — privremena greška, pokušaću ponovo" }
        return ""
    }
}

/// Linijski sloj veze — pravi (TLS) ili skriptovan u testovima.
protocol SMTPLink: AnyObject {
    func open() async throws
    func send(_ s: String) async throws
    func readResponse() async throws -> (code: Int, text: String)
    func close()
}

protocol MailTransport {
    func send(from: String, to: [String], mime: String) async throws
}

struct SMTPClient: MailTransport {
    var user: String
    var password: String
    var makeLink: () -> SMTPLink

    init(host: String, port: Int, user: String, password: String) {
        self.user = user
        self.password = password
        self.makeLink = { TLSLink(host: host, port: port) }
    }

    init(user: String, password: String, link: @escaping () -> SMTPLink) {
        self.user = user
        self.password = password
        self.makeLink = link
    }

    func send(from: String, to: [String], mime: String) async throws {
        guard !user.isEmpty, !password.isEmpty else { throw SMTPError.missingCredentials }
        let link = makeLink()
        defer { link.close() }
        try await link.open()

        func expect(_ step: String, _ ok: Set<Int>) async throws {
            let r = try await link.readResponse()
            guard ok.contains(r.code) else { throw SMTPError.unexpected(step: step, code: r.code, text: r.text) }
        }

        try await expect("pozdrav", [220])
        try await link.send("EHLO slackmail.local\r\n")
        try await expect("EHLO", [250])
        let auth = Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedString()
        try await link.send("AUTH PLAIN \(auth)\r\n")
        try await expect("prijava", [235])
        try await link.send("MAIL FROM:<\(MailComposer.headerSafe(from))>\r\n")
        try await expect("pošiljalac", [250])
        for rcpt in to {
            try await link.send("RCPT TO:<\(MailComposer.headerSafe(rcpt))>\r\n")
            try await expect("primalac \(rcpt)", [250, 251])
        }
        try await link.send("DATA\r\n")
        try await expect("DATA", [354])
        try await link.send(Self.dotStuff(mime) + "\r\n.\r\n")
        try await expect("slanje", [250])
        try? await link.send("QUIT\r\n")
    }

    /// Linija koja počinje tačkom dobija još jednu (RFC 5321 §4.5.2).
    static func dotStuff(_ s: String) -> String {
        let normalized = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        return normalized.components(separatedBy: "\r\n")
            .map { $0.hasPrefix(".") ? "." + $0 : $0 }
            .joined(separator: "\r\n")
    }

    /// Parsira višelinijski SMTP odgovor ("250-…" pa "250 …"); vraća nil ako nije kompletan.
    static func parseResponse(_ buffer: String) -> (code: Int, text: String, consumed: Int)? {
        var consumed = 0
        var lines: [String] = []
        var rest = Substring(buffer)
        while let r = rest.range(of: "\r\n") {
            let line = String(rest[rest.startIndex..<r.lowerBound])
            consumed += line.utf8.count + 2
            rest = rest[r.upperBound...]
            lines.append(line)
            let isLast = line.count <= 3 || line[line.index(line.startIndex, offsetBy: 3)] == " "
            if isLast {
                let code = Int(line.prefix(3)) ?? 0
                let text = lines.map { String($0.dropFirst(4)) }.joined(separator: " ")
                return (code, text, consumed)
            }
        }
        return nil
    }
}

/// TLS veza preko Network.framework-a (port 465 = implicitni TLS).
final class TLSLink: SMTPLink, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "smtp")
    private var buffer = ""

    init(host: String, port: Int) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                                  using: .tls)
    }

    func open() async throws {
        try await withTimeout(20, onTimeout: { [connection] in connection.cancel() }) { [connection, queue] in
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // Handler se izvršava na serijskom redu `queue`, pa je zastavica bezbedna.
                let once = OnceFlag()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if once.claim() { cont.resume() }
                    case .failed(let e), .waiting(let e):
                        if once.claim() { cont.resume(throwing: SMTPError.connection(e.localizedDescription)) }
                    case .cancelled:
                        if once.claim() { cont.resume(throwing: SMTPError.timeout) }
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }
    }

    func send(_ s: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(s.utf8), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: SMTPError.connection(error.localizedDescription)) } else { cont.resume() }
            })
        }
    }

    func readResponse() async throws -> (code: Int, text: String) {
        try await withTimeout(30, onTimeout: { [connection] in connection.cancel() }) { [self] in
            while true {
                if let r = SMTPClient.parseResponse(buffer) {
                    buffer = String(buffer.utf8.dropFirst(r.consumed)) ?? ""
                    return (r.code, r.text)
                }
                let chunk = try await receive()
                buffer += chunk
            }
        }
    }

    private func receive() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error { cont.resume(throwing: SMTPError.connection(error.localizedDescription)); return }
                if let data, !data.isEmpty { cont.resume(returning: String(decoding: data, as: UTF8.self)); return }
                if isComplete { cont.resume(throwing: SMTPError.connection("server je zatvorio vezu")); return }
                cont.resume(returning: "")
            }
        }
    }

    func close() { connection.cancel() }
}

final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Vraća rezultat `op`, ili posle `seconds` poziva `onTimeout` (zatvara vezu) i baca `.timeout`.
/// Namerno bez task grupe: vraća se i kada `op` čeka continuation koji niko nikad ne nastavi.
func withTimeout<T: Sendable>(_ seconds: Double, onTimeout: @escaping @Sendable () -> Void = {},
                              _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = OnceFlag()
    let timer = TaskBox()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let work = Task {
            do {
                let v = try await op()
                if once.claim() { timer.cancel(); cont.resume(returning: v) }
            } catch {
                if once.claim() { timer.cancel(); cont.resume(throwing: error) }
            }
        }
        timer.set(Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, once.claim() else { return }
            onTimeout()
            work.cancel()
            cont.resume(throwing: SMTPError.timeout)
        })
    }
}

final class TaskBox: @unchecked Sendable {
    private var task: Task<Void, Never>?
    private var cancelled = false
    private let lock = NSLock()
    func set(_ t: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if cancelled { t.cancel() } else { task = t }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}
