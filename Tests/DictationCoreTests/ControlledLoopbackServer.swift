import Darwin
import Foundation

final class ControlledLoopbackServer: @unchecked Sendable {
    struct Request: Sendable { let path: String; let authorization: String? }
    private let lock = NSLock()
    private var received: [Request] = []
    private let listener: Int32
    private let challenge: Bool
    let baseURL: String
    var requests: [Request] { lock.withLock { received } }

    init(challenge: Bool = false) throws {
        self.challenge = challenge
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        listener = descriptor
        guard descriptor >= 0 else { throw ServerError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 4) == 0 else { close(listener); throw ServerError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { close(listener); throw ServerError.socket }
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        DispatchQueue(label: "dictation-test-loopback").async { [self] in serve() }
    }

    func stop() { shutdown(listener, SHUT_RDWR) }

    private func serve() {
        defer { close(listener) }
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var noSignal: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            respond(connection)
            close(connection)
        }
    }

    private func respond(_ connection: Int32) {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var headerEnd: Int?
        var expected = 0
        while bytes.count < 2 * 1_024 * 1_024 {
            let count = recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            bytes.append(contentsOf: buffer.prefix(count))
            if headerEnd == nil, let end = bytes.range(of: Data("\r\n\r\n".utf8))?.upperBound,
               let header = String(data: bytes.prefix(end), encoding: .utf8) {
                headerEnd = end
                let lines = header.components(separatedBy: "\r\n")
                expected = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }).flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                let authorization = lines.first(where: { $0.lowercased().hasPrefix("authorization:") }).map { String($0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)) }
                let path = lines.first?.components(separatedBy: " ").dropFirst().first ?? ""
                lock.withLock { received.append(Request(path: path, authorization: authorization)) }
            }
            if let headerEnd, bytes.count - headerEnd >= expected { break }
        }
        let body = challenge ? "{\"error\":{\"message\":\"authentication required\"}}" : "{\"text\":\"受控本机转写。\"}"
        let status = challenge ? "401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"controlled\"" : "200 OK"
        let response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        response.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var sent = 0
            while sent < pointer.count {
                let count = send(connection, base.advanced(by: sent), pointer.count - sent, 0)
                guard count > 0 else { return }
                sent += count
            }
        }
    }
}

private enum ServerError: Error { case socket }
