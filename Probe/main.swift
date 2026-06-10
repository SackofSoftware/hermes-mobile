// M0 protocol probe for Hermes Mobile.
//
// Connects to a running Hermes Agent over the documented "Model A" path
// (token query param on /api/ws), creates a session, submits one prompt, and
// logs every JSON-RPC frame + server event so we can confirm the wire protocol
// and event payload shapes against the REAL server.
//
// Usage:
//   SERVER_URL=http://host:9119 HERMES_TOKEN=... swift Probe/main.swift
// Optional:
//   PROMPT="..."            (default: a harmless 'reply pong' prompt)
//   IDLE_TIMEOUT=60         (seconds to wait for the next frame before giving up)
//
// Writes a raw frame log to Probe/fixtures/session-events.jsonl for reuse as a
// reduction-test fixture (Task 3 / Task 8 in the plan).

import Foundation

// MARK: - Config

let env = ProcessInfo.processInfo.environment

guard let serverURLString = env["SERVER_URL"], !serverURLString.isEmpty,
      let token = env["HERMES_TOKEN"], !token.isEmpty
else {
    FileHandle.standardError.write(Data("ERROR: set SERVER_URL and HERMES_TOKEN env vars.\n".utf8))
    exit(2)
}

let prompt = env["PROMPT"] ?? "Reply with exactly the single word: pong"
let idleTimeout = Double(env["IDLE_TIMEOUT"] ?? "60") ?? 60

func makeWSURL(from base: String) -> URL? {
    guard var comps = URLComponents(string: base) else { return nil }
    comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
    comps.path = "/api/ws"
    comps.queryItems = [URLQueryItem(name: "token", value: token)]
    return comps.url
}

guard let wsURL = makeWSURL(from: serverURLString) else {
    FileHandle.standardError.write(Data("ERROR: could not build WS URL from SERVER_URL=\(serverURLString)\n".utf8))
    exit(2)
}

// MARK: - Logging

let startedAt = Date()
func ts() -> String { String(format: "%7.2fs", Date().timeIntervalSince(startedAt)) }
func log(_ s: String) { print("[\(ts())] \(s)") }

// MARK: - Probe

enum ProbeError: Error { case idleTimeout }

final class Probe: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let redact: String
    private var idCounter = 0
    private var sessionID: String?
    private var sentPrompt = false
    private var sawComplete = false
    private var deltaCount = 0
    private var rawFrames: [String] = []
    private var eventTypes: [String] = []

    init(url: URL, redact: String) {
        let session = URLSession(configuration: .default)
        self.task = session.webSocketTask(with: url)
        self.redact = redact
    }

    private func nextID() -> Int { idCounter += 1; return idCounter }

    private func send(method: String, params: [String: Any]) async throws {
        let id = nextID()
        let obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        let str = String(decoding: data, as: UTF8.self)
        log("→ SEND  \(method) (id=\(id)) \(str)")
        try await task.send(.string(str))
    }

    private func receive(timeout: Double) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await self.task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ProbeError.idleTimeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func run() async {
        log("connecting → \(task.originalRequest?.url?.absoluteString.replacingOccurrences(of: redact, with: "***") ?? "?")")
        task.resume()

        do {
            try await send(method: "session.create", params: ["title": "M0 probe", "cols": 80])
        } catch {
            log("✗ failed to send session.create: \(error)")
            finish(ok: false)
            return
        }

        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await receive(timeout: idleTimeout)
            } catch ProbeError.idleTimeout {
                log("⏱  idle for \(Int(idleTimeout))s — stopping")
                break
            } catch {
                log("connection closed / receive error: \(error)")
                break
            }

            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }

            // Newline-delimited JSON: a single WS message may carry >1 frame.
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                await handle(frame: String(line))
            }

            if sawComplete { break }
        }

        finish(ok: sawComplete)
    }

    private func handle(frame: String) async {
        rawFrames.append(frame)
        guard let data = frame.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            log("← FRAME (unparseable): \(frame.prefix(200))")
            return
        }

        // Event notification: {"method":"event","params":{"type":...,"payload":...}}
        if let method = obj["method"] as? String, method == "event",
           let params = obj["params"] as? [String: Any],
           let type = params["type"] as? String {
            eventTypes.append(type)
            let payload = params["payload"] as? [String: Any] ?? [:]
            summarizeEvent(type: type, payload: payload, raw: frame)

            switch type {
            case "session.info":
                if sessionID == nil, let sid = payload["session_id"] as? String ?? params["session_id"] as? String {
                    sessionID = sid
                }
            case "message.delta":
                deltaCount += 1
            case "message.complete":
                sawComplete = true
            default:
                break
            }

            // Once we know the session id, fire the prompt exactly once.
            await submitPromptIfReady()
            return
        }

        // JSON-RPC response: {"id":N,"result":...} or {"id":N,"error":...}
        if let id = obj["id"] {
            if let result = obj["result"] as? [String: Any] {
                log("← RESULT (id=\(id)) \(compact(result))")
                if sessionID == nil, let sid = result["session_id"] as? String { sessionID = sid }
                await submitPromptIfReady()
            } else if let err = obj["error"] {
                log("← ERROR  (id=\(id)) \(err)")
            } else {
                log("← RESPONSE (id=\(id)) \(frame.prefix(200))")
            }
            return
        }

        log("← OTHER \(frame.prefix(200))")
    }

    private func submitPromptIfReady() async {
        guard !sentPrompt, let sid = sessionID else { return }
        sentPrompt = true
        log("✓ session_id = \(sid)")
        do {
            try await send(method: "prompt.submit", params: ["session_id": sid, "text": prompt])
            log("   prompt: \"\(prompt)\"")
        } catch {
            log("✗ failed to send prompt.submit: \(error)")
        }
    }

    private func summarizeEvent(type: String, payload: [String: Any], raw: String) {
        switch type {
        case "message.delta":
            let t = (payload["text"] as? String) ?? ""
            log("← event message.delta  text=\(quoted(t))")
        case "message.complete":
            let t = (payload["text"] as? String) ?? ""
            log("← event message.complete  text=\(quoted(String(t.prefix(120))))  keys=\(Array(payload.keys).sorted())")
        case "tool.start":
            log("← event tool.start  name=\(payload["name"] ?? "?")  keys=\(Array(payload.keys).sorted())")
        case "tool.complete":
            log("← event tool.complete  name=\(payload["name"] ?? "?")  keys=\(Array(payload.keys).sorted())")
        case "status.update":
            log("← event status.update  \(compact(payload))")
        default:
            log("← event \(type)  keys=\(Array(payload.keys).sorted())")
        }
    }

    private func quoted(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\n", with: "\\n"))\"" }
    private func compact(_ d: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return "\(d)" }
        return String(decoding: data, as: UTF8.self)
    }

    private func finish(ok: Bool) {
        task.cancel(with: .goingAway, reason: nil)
        writeFixture()
        print("\n========== M0 PROBE SUMMARY ==========")
        print("session created : \(sessionID != nil ? "YES (\(sessionID!))" : "NO")")
        print("prompt submitted: \(sentPrompt ? "YES" : "NO")")
        print("message.delta   : \(deltaCount) frame(s)")
        print("message.complete: \(sawComplete ? "YES" : "NO")")
        let distinct = Array(Set(eventTypes)).sorted()
        print("event types seen: \(distinct.isEmpty ? "(none)" : distinct.joined(separator: ", "))")
        print("raw frames      : \(rawFrames.count) → Probe/fixtures/session-events.jsonl")
        print("result          : \(ok ? "✅ streaming loop confirmed" : "⚠️  did not reach message.complete — see log above")")
        print("======================================")
    }

    private func writeFixture() {
        let dir = "Probe/fixtures"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let body = rawFrames.joined(separator: "\n") + "\n"
        try? body.write(toFile: "\(dir)/session-events.jsonl", atomically: true, encoding: .utf8)
    }
}

// MARK: - Entry point (script mode)

let probe = Probe(url: wsURL, redact: token)
let done = DispatchSemaphore(value: 0)
Task {
    await probe.run()
    done.signal()
}
done.wait()
