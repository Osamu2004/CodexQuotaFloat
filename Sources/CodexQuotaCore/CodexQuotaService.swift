import Foundation

public final class CodexQuotaService {
    private let fileManager = FileManager.default
    private let fallbackReader = LocalQuotaLogReader()
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 12) {
        self.timeout = timeout
    }

    public func fetch() throws -> QuotaReading {
        do {
            return try fetchLive()
        } catch {
            return try fallbackReader.latestReading(liveError: error)
        }
    }

    public func fetchLive() throws -> QuotaReading {
        let binary = try locateCodexBinary()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = binary
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stateLock = NSLock()
        let responseSignal = DispatchSemaphore(value: 0)
        var stdoutBuffer = Data()
        var responseLine: Data?
        var signalSent = false
        var stderrBuffer = Data()

        func signalOnce() {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !signalSent else { return }
            signalSent = true
            responseSignal.signal()
        }

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }

            stateLock.lock()
            stdoutBuffer.append(chunk)
            while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
                let line = stdoutBuffer.prefix(upTo: newline)
                stdoutBuffer.removeSubrange(...newline)

                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let id = object["id"] as? NSNumber,
                   id.intValue == 2 {
                    responseLine = Data(line)
                    stateLock.unlock()
                    signalOnce()
                    return
                }
            }
            stateLock.unlock()
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stateLock.lock()
            if stderrBuffer.count < 64 * 1024 {
                stderrBuffer.append(chunk.prefix(64 * 1024 - stderrBuffer.count))
            }
            stateLock.unlock()
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw CodexQuotaError.appServerLaunchFailed(error.localizedDescription)
        }

        let initialize = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-quota-float","title":"Codex Quota Float","version":"0.1.0"}}}"#
        let initialized = #"{"method":"initialized"}"#
        let request = #"{"id":2,"method":"account/rateLimits/read"}"#
        let payload = [initialize, initialized, request].joined(separator: "\n") + "\n"

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        } catch {
            stop(process, output: outputPipe, error: errorPipe, input: inputPipe)
            throw CodexQuotaError.appServerLaunchFailed(error.localizedDescription)
        }

        let waitResult = responseSignal.wait(timeout: .now() + timeout)

        stateLock.lock()
        let capturedResponse = responseLine
        let capturedError = String(decoding: stderrBuffer, as: UTF8.self)
        stateLock.unlock()

        stop(process, output: outputPipe, error: errorPipe, input: inputPipe)

        guard waitResult == .success else {
            if !capturedError.isEmpty {
                throw CodexQuotaError.appServerLaunchFailed(String(capturedError.prefix(500)))
            }
            throw CodexQuotaError.appServerTimedOut
        }
        guard let capturedResponse else {
            throw CodexQuotaError.invalidResponse
        }
        return try QuotaProtocolParser.parseRateLimitResponse(capturedResponse)
    }

    public func resolvedBinaryPath() -> String? {
        (try? locateCodexBinary())?.path
    }

    private func locateCodexBinary() throws -> URL {
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = [
            // ChatGPT desktop (the Codex app is now integrated) ships the CLI
            // in the codex-cli bundle. Keep both the wrapper and the native
            // executable as candidates because their layout differs by build.
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"),
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            // Older builds shipped the CLI directly at this path.
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
            // Keep the legacy standalone Codex.app locations for older installs.
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("codex")
            })
        }

        if let match = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) {
            return match
        }
        throw CodexQuotaError.codexBinaryNotFound
    }

    private func stop(_ process: Process, output: Pipe, error: Pipe, input: Pipe) {
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? error.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
        }
    }
}
