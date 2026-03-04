import Foundation

/// Manages the lifecycle of a local llama-server process for Qwen text cleanup.
///
/// On app launch, checks if port 8179 is already in use. If not, and the Qwen model
/// file exists at the expected path, starts llama-server as a child process.
/// Kills the process on app quit.
@MainActor
final class LlamaServerManager {

    // MARK: - Configuration

    private static let port: UInt16 = 8179
    private static let llamaServerPath = "/opt/homebrew/bin/llama-server"
    private static let modelPath = NSString("~/Documents/Models/qwen3.5-2b-q4_k_m.gguf").expandingTildeInPath

    // MARK: - State

    private var serverProcess: Process?
    private(set) var didStartServer = false

    // MARK: - Public

    /// Start llama-server if port 8179 is free and the Qwen model exists.
    /// Safe to call multiple times — no-ops if already running or port is taken.
    func startIfNeeded() {
        // Don't start twice
        guard serverProcess == nil else { return }

        // Check if port is already in use (another instance or user-started server)
        guard !Self.isPortInUse(Self.port) else {
            print("[LlamaServer] Port \(Self.port) already in use — skipping auto-start")
            return
        }

        // Check if llama-server binary exists
        guard FileManager.default.isExecutableFile(atPath: Self.llamaServerPath) else {
            print("[LlamaServer] llama-server not found at \(Self.llamaServerPath)")
            return
        }

        // Check if model file exists
        guard FileManager.default.fileExists(atPath: Self.modelPath) else {
            print("[LlamaServer] Qwen model not found at \(Self.modelPath)")
            return
        }

        // Launch llama-server
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.llamaServerPath)
        process.arguments = [
            "--model", Self.modelPath,
            "--port", String(Self.port),
            "--ctx-size", "2048",
            "--threads", "4",
            "--log-disable"
        ]

        // Suppress stdout/stderr to avoid noise in console
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            serverProcess = process
            didStartServer = true
            print("[LlamaServer] Started llama-server (PID \(process.processIdentifier)) on port \(Self.port)")

            // Clean up state if the process exits unexpectedly (crash, killed externally)
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.serverProcess = nil
                    self.didStartServer = false
                    print("[LlamaServer] Process terminated unexpectedly — state cleared for restart")
                }
            }
        } catch {
            print("[LlamaServer] Failed to start: \(error.localizedDescription)")
        }
    }

    /// Kill the llama-server process if we started it.
    /// Uses synchronous waits so the process is guaranteed dead before returning
    /// (important during applicationWillTerminate where async blocks may not run).
    func stop() {
        guard let process = serverProcess, process.isRunning else {
            serverProcess = nil
            return
        }

        print("[LlamaServer] Stopping llama-server (PID \(process.processIdentifier))")

        // Clear the terminationHandler to avoid conflicting state changes
        process.terminationHandler = nil

        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }

        // SIGTERM for graceful shutdown
        process.terminate()

        // Wait up to 2 seconds for graceful exit
        if group.wait(timeout: .now() + 2.0) == .timedOut, process.isRunning {
            // SIGINT as second attempt
            process.interrupt()
            if group.wait(timeout: .now() + 1.0) == .timedOut, process.isRunning {
                // Force kill as last resort
                kill(process.processIdentifier, SIGKILL)
            }
        }

        serverProcess = nil
        didStartServer = false
    }

    // MARK: - Port Check

    /// Check if a TCP port is in use on localhost.
    private static func isPortInUse(_ port: UInt16) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }
}
