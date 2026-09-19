import Foundation
import Network

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }
}

enum UnixDaemonTransport {
    static var socketPath: String {
        if let env = ProcessInfo.processInfo.environment["ASTER_DATA_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true).appendingPathComponent("daemon.sock").path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/Aster/daemon.sock").path
    }

    static func socketAvailable() -> Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    static func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard socketAvailable() else { throw URLError(.cannotConnectToHost) }
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 30
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                try await perform(request)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw URLError(.timedOut)
            }
            guard let first = try await group.next() else {
                throw URLError(.cannotConnectToHost)
            }
            group.cancelAll()
            return first
        }
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let payload = try encodeHTTPRequest(request)
        let conn = NWConnection(to: .unix(path: socketPath), using: .tcp)
        try await connect(conn)
        defer { conn.cancel() }
        try await send(conn, payload)
        let raw = try await readHTTPMessage(conn)
        return try decodeHTTPResponse(raw, url: url)
    }

    fileprivate static func connect(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = ResumeGate()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.stateUpdateHandler = nil
                    gate.resume { cont.resume() }
                case .failed(let err):
                    conn.stateUpdateHandler = nil
                    gate.resume { cont.resume(throwing: err) }
                case .cancelled:
                    conn.stateUpdateHandler = nil
                    gate.resume { cont.resume(throwing: URLError(.cancelled)) }
                case .waiting(let err):
                    if case .posix(.ENOENT) = err {
                        conn.stateUpdateHandler = nil
                        conn.cancel()
                        gate.resume { cont.resume(throwing: err) }
                    }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    fileprivate static func send(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    fileprivate static func receive(_ conn: NWConnection, min: Int = 1, max: Int = 64 * 1024) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: min, maximumLength: max) { content, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let content, !content.isEmpty {
                    cont.resume(returning: content)
                } else if isComplete {
                    cont.resume(throwing: URLError(.networkConnectionLost))
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    private static func readHTTPMessage(_ conn: NWConnection) async throws -> Data {
        var buffer = Data()
        let headerSep = Data("\r\n\r\n".utf8)
        while buffer.range(of: headerSep) == nil {
            buffer.append(try await receive(conn))
            if buffer.count > 1024 * 1024 {
                throw URLError(.dataLengthExceedsMaximum)
            }
        }
        guard let sep = buffer.range(of: headerSep) else {
            throw URLError(.badServerResponse)
        }
        let headerData = buffer.subdata(in: buffer.startIndex..<sep.lowerBound)
        var body = buffer.subdata(in: sep.upperBound..<buffer.endIndex)
        let headers = String(decoding: headerData, as: UTF8.self)
        if let length = contentLength(from: headers) {
            while body.count < length {
                body.append(try await receive(conn, min: 1, max: max(length - body.count, 1)))
            }
            if body.count > length {
                body = body.prefix(length)
            }
        }
        var message = Data()
        message.append(headerData)
        message.append(headerSep)
        message.append(body)
        return message
    }

    private static func encodeHTTPRequest(_ request: URLRequest) throws -> Data {
        guard let url = request.url else { throw URLError(.badURL) }
        let method = request.httpMethod ?? "GET"
        var path = url.path
        if path.isEmpty { path = "/" }
        if let query = url.query, !query.isEmpty {
            path += "?" + query
        }
        var lines = [
            "\(method) \(path) HTTP/1.1",
            "Host: localhost",
            "Connection: close",
        ]
        request.allHTTPHeaderFields?.forEach { key, value in
            if key.caseInsensitiveCompare("Host") == .orderedSame { return }
            if key.caseInsensitiveCompare("Connection") == .orderedSame { return }
            lines.append("\(key): \(value)")
        }
        let body = request.httpBody ?? Data()
        if request.value(forHTTPHeaderField: "Content-Length") == nil {
            lines.append("Content-Length: \(body.count)")
        }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }

    private static func decodeHTTPResponse(_ raw: Data, url: URL) throws -> (Data, URLResponse) {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: sep) else { throw URLError(.badServerResponse) }
        let head = String(decoding: raw.subdata(in: raw.startIndex..<range.lowerBound), as: UTF8.self)
        let body = raw.subdata(in: range.upperBound..<raw.endIndex)
        let lines = head.split(whereSeparator: \.isNewline).map(String.init)
        guard let statusLine = lines.first else { throw URLError(.badServerResponse) }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { throw URLError(.badServerResponse) }
        var headerFields: [String: String] = [:]
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let idx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<idx])
            let value = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            headerFields[key] = value
        }
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headerFields)
        guard let response else { throw URLError(.badServerResponse) }
        return (body, response)
    }

    private static func contentLength(from headers: String) -> Int? {
        for line in headers.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("content-length:") {
                return Int(trimmed.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}

final class UnixWebSocket: @unchecked Sendable {
    typealias ReceiveHandler = (Result<URLSessionWebSocketTask.Message, Error>) -> Void

    // The websocket callback originates on Network.framework's queue but is
    // consumed by MainActor-bound SwiftUI state. This container is the single,
    // immutable value intentionally passed between those queues; delivery is
    // always performed on the main queue below.
    private final class ReceiveDelivery: @unchecked Sendable {
        let callback: ReceiveHandler
        let result: Result<URLSessionWebSocketTask.Message, Error>

        init(_ callback: @escaping ReceiveHandler, _ result: Result<URLSessionWebSocketTask.Message, Error>) {
            self.callback = callback
            self.result = result
        }
    }
    private let path: String
    private let token: String
    private var connection: NWConnection?
    private var buffer = Data()
    private var pending: ReceiveHandler?
    private var queued: [URLSessionWebSocketTask.Message] = []
    private var closed: Error?
    private let lock = NSLock()
    private var started = false

    init(path: String, token: String) {
        self.path = path.hasPrefix("/") ? path : "/" + path
        self.token = token
    }

    func resume() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        Task { [self] in
            await open()
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode = .goingAway, reason: Data? = nil) {
        fail(URLError(.cancelled))
        connection?.cancel()
        connection = nil
    }

    // AsterState is MainActor-isolated. NWConnection invokes us on its own
    // queue, so every outward delivery must cross back to the main queue
    // before it reaches the SwiftUI state object. Calling an actor-inherited
    // callback directly here traps under Swift 6's runtime isolation checks.
    func receive(completionHandler: @escaping ReceiveHandler) {
        lock.lock()
        if let closed {
            lock.unlock()
            deliverOnMain(completionHandler, .failure(closed))
            return
        }
        if !queued.isEmpty {
            let next = queued.removeFirst()
            lock.unlock()
            deliverOnMain(completionHandler, .success(next))
            return
        }
        pending = completionHandler
        lock.unlock()
    }

    private func open() async {
        do {
            let conn = NWConnection(to: .unix(path: UnixDaemonTransport.socketPath), using: .tcp)
            try await UnixDaemonTransport.connect(conn)
            connection = conn
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            var headers = [
                "GET \(path) HTTP/1.1",
                "Host: localhost",
                "Upgrade: websocket",
                "Connection: Upgrade",
                "Sec-WebSocket-Version: 13",
                "Sec-WebSocket-Key: \(key)",
            ]
            if !token.isEmpty {
                headers.append("Authorization: Bearer \(token)")
            }
            try await UnixDaemonTransport.send(conn, Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8))
            var raw = Data()
            let sep = Data("\r\n\r\n".utf8)
            while raw.range(of: sep) == nil {
                raw.append(try await UnixDaemonTransport.receive(conn))
            }
            guard let range = raw.range(of: sep) else { throw URLError(.badServerResponse) }
            let head = String(decoding: raw.subdata(in: raw.startIndex..<range.lowerBound), as: UTF8.self)
            guard head.contains(" 101 ") else { throw URLError(.badServerResponse) }
            let leftover = raw.subdata(in: range.upperBound..<raw.endIndex)
            if !leftover.isEmpty {
                ingest(leftover)
            }
            readLoop(conn)
        } catch {
            fail(error)
        }
    }

    private func readLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.fail(error)
                return
            }
            if let content, !content.isEmpty {
                self.ingest(content)
            }
            if isComplete {
                self.fail(URLError(.networkConnectionLost))
                return
            }
            self.readLoop(conn)
        }
    }

    private func ingest(_ data: Data) {
        lock.lock()
        buffer.append(data)
        while let frame = popFrame() {
            switch frame.opcode {
            case 1:
                if let text = String(data: frame.payload, encoding: .utf8) {
                    deliverLocked(.string(text))
                }
            case 2:
                deliverLocked(.data(frame.payload))
            case 8:
                lock.unlock()
                fail(URLError(.networkConnectionLost))
                return
            case 9:
                lock.unlock()
                sendPong(frame.payload)
                lock.lock()
            default:
                break
            }
        }
        lock.unlock()
    }

    private func deliverLocked(_ message: URLSessionWebSocketTask.Message) {
        if let pending {
            self.pending = nil
            lock.unlock()
            deliverOnMain(pending, .success(message))
            lock.lock()
        } else {
            queued.append(message)
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        closed = error
        let callback = pending
        pending = nil
        queued.removeAll()
        lock.unlock()
        if let callback {
            deliverOnMain(callback, .failure(error))
        }
        connection?.cancel()
        connection = nil
    }

    private func deliverOnMain(_ callback: @escaping ReceiveHandler, _ result: Result<URLSessionWebSocketTask.Message, Error>) {
        let delivery = ReceiveDelivery(callback, result)
        if Thread.isMainThread {
            delivery.callback(delivery.result)
        } else {
            DispatchQueue.main.async {
                delivery.callback(delivery.result)
            }
        }
    }

    private func sendPong(_ payload: Data) {
        guard let conn = connection else { return }
        let frame = Self.encodeFrame(opcode: 0xA, payload: payload)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private struct Frame {
        let opcode: UInt8
        let payload: Data
    }

    private func popFrame() -> Frame? {
        guard buffer.count >= 2 else { return nil }
        let b0 = buffer[buffer.startIndex]
        let b1 = buffer[buffer.startIndex + 1]
        let opcode = b0 & 0x0F
        var len = Int(b1 & 0x7F)
        var offset = 2
        if len == 126 {
            guard buffer.count >= 4 else { return nil }
            len = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
            offset = 4
        } else if len == 127 {
            return nil
        }
        let masked = (b1 & 0x80) != 0
        if masked { offset += 4 }
        guard buffer.count >= offset + len else { return nil }
        var payload = buffer.subdata(in: (buffer.startIndex + offset)..<(buffer.startIndex + offset + len))
        if masked {
            let maskStart = buffer.startIndex + offset - 4
            let mask = buffer.subdata(in: maskStart..<(maskStart + 4))
            for i in 0..<payload.count {
                payload[i] ^= mask[i % 4]
            }
        }
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset + len))
        return Frame(opcode: opcode, payload: payload)
    }

    private static func encodeFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode)
        let maskKey = (0..<4).map { _ in UInt8.random(in: 0...255) }
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else {
            frame.append(0x80 | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        }
        frame.append(contentsOf: maskKey)
        var masked = payload
        for i in 0..<masked.count {
            masked[i] ^= maskKey[i % 4]
        }
        frame.append(masked)
        return frame
    }
}
