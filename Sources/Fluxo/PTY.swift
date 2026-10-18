import Darwin
import Foundation

/// Roda um programa num pseudo-terminal. Alguns programas do sistema (networkQuality,
/// nettop) só imprimem o andamento ao vivo quando a saída é um terminal; num pipe comum,
/// guardam tudo até o fim.
enum PTY {
    struct Output {
        let text: String
        let status: Int32
    }

    /// `collect: false` não acumula a saída (para programas que rodam sem parar).
    static func run(_ path: String, _ arguments: [String], running: RunningProcess, collect: Bool = true,
                    onLine: @escaping @Sendable (String) -> Void) async throws -> Output {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var master: Int32 = 0
                var slave: Int32 = 0
                var size = winsize(ws_row: 50, ws_col: 400, ws_xpixel: 0, ws_ypixel: 0)
                guard openpty(&master, &slave, nil, nil, &size) == 0 else {
                    cont.resume(throwing: SpeedTestError(message: "Não consegui abrir um terminal para rodar \(path)."))
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
                process.standardOutput = slaveHandle
                process.standardError = slaveHandle
                process.standardInput = FileHandle.nullDevice
                do {
                    try running.start(process)
                } catch {
                    close(master)
                    close(slave)
                    cont.resume(throwing: error is CancellationError ? error
                                : SpeedTestError(message: "\(path) não abriu: \(error.localizedDescription)"))
                    return
                }
                // Sem a nossa cópia do slave, o read() abaixo termina quando o processo sai.
                close(slave)

                var all = Data()
                var pending = ""
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(master, &buffer, buffer.count)
                    if n <= 0 { break }
                    if collect { all.append(buffer, count: n) }
                    pending += String(decoding: buffer[0..<n], as: UTF8.self)
                    // Programas que se atualizam na mesma linha usam \r.
                    var parts = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                    pending = parts.removeLast()
                    for line in parts where !line.isEmpty {
                        onLine(stripANSI(line))
                    }
                }
                close(master)
                process.waitUntilExit()
                cont.resume(returning: Output(text: stripANSI(String(decoding: all, as: UTF8.self)),
                                              status: process.terminationStatus))
            }
        }
    }

    static func stripANSI(_ s: String) -> String {
        s.replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "")
    }
}

/// Guarda o processo para poder encerrá-lo (teste cancelado, painel fechado).
final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func start(_ p: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try p.run()
        process = p
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process?.isRunning == true { process?.terminate() }
    }
}
