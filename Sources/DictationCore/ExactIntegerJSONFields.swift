import Foundation

enum ExactIntegerJSONFields {
    // 调用方先用系统 decoder 验证 JSON 与字段类型，这里只核验原始数字的整数性。
    static func areIntegers(_ names: Set<String>, in data: Data) -> Bool {
        guard data.count >= 4, let tokens = tokens(in: data) else { return false }
        var depth = 0
        var found = Set<String>()
        for index in tokens.indices {
            switch tokens[index] {
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            default:
                guard depth == 1, tokens[index].first == "\"", index + 2 < tokens.count, tokens[index + 1] == ":",
                      let name = try? JSONDecoder().decode(String.self, from: Data(tokens[index].utf8)), names.contains(name) else { continue }
                guard isInteger(tokens[index + 2]) else { return false }
                found.insert(name)
            }
        }
        return found == names
    }

    static func isRootInteger(in data: Data) -> Bool {
        guard let tokens = tokens(in: data), tokens.count == 1 else { return false }
        return isInteger(tokens[0])
    }

    private static func tokens(in data: Data) -> [String]? {
        let prefix = Array(data.prefix(4))
        let encoding: String.Encoding
        if prefix.count == 4 {
            switch (prefix[0], prefix[1], prefix[2], prefix[3]) {
            case (0, 0, 0, _), (0, 0, 254, 255): encoding = .utf32BigEndian
            case (_, 0, 0, 0), (255, 254, 0, 0): encoding = .utf32LittleEndian
            case (0, _, 0, _), (254, 255, _, _): encoding = .utf16BigEndian
            case (_, 0, _, 0), (255, 254, _, _): encoding = .utf16LittleEndian
            default: encoding = .utf8
            }
        } else if prefix.count == 2, prefix[0] == 0 {
            encoding = .utf16BigEndian
        } else if prefix.count == 2, prefix[1] == 0 {
            encoding = .utf16LittleEndian
        } else {
            encoding = .utf8
        }
        guard var source = String(data: data, encoding: encoding),
              let lexer = try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"|[{}\[\]:,]|[^\s{}\[\]:,]+"#) else { return nil }
        // 显式端序解码会保留 BOM，但系统 JSON decoder 已接纳此源。
        if source.first == "\u{FEFF}" { source.removeFirst() }
        let text = source as NSString
        return lexer.matches(in: source, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range) }
    }

    private static func isInteger(_ token: String) -> Bool {
        guard let first = token.utf8.first, first == 45 || (48...57).contains(first) else { return false }
        let parts = token.split(whereSeparator: { $0 == "e" || $0 == "E" })
        guard let mantissa = parts.first, parts.count <= 2 else { return false }
        let digits = mantissa.utf8.filter { (48...57).contains($0) }
        // 零不依赖指数范围；系统 decoder 已确认数字合法。
        if !digits.isEmpty, digits.allSatisfy({ $0 == 48 }) { return true }
        let exponent = parts.count == 1 ? 0 : Int(parts[1])
        guard let exponent else { return false }
        let fractionalDigits = mantissa.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        let (places, overflow) = fractionalDigits.subtractingReportingOverflow(exponent)
        guard !overflow else { return false }
        return places <= 0 || digits.suffix(places).allSatisfy { $0 == 48 }
    }
}
