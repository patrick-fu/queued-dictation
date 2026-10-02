import Foundation

enum ExactIntegerJSONFields {
    // 调用方先用系统 decoder 验证 JSON 与字段类型，这里只核验根字段的原始整数性。
    static func areIntegers(_ names: Set<String>, in data: Data) -> Bool {
        let prefix = Array(data.prefix(4))
        guard prefix.count == 4 else { return false }
        let encoding: String.Encoding
        switch (prefix[0], prefix[1], prefix[2], prefix[3]) {
        case (0, 0, 0, _), (0, 0, 254, 255): encoding = .utf32BigEndian
        case (_, 0, 0, 0), (255, 254, 0, 0): encoding = .utf32LittleEndian
        case (0, _, 0, _), (254, 255, _, _): encoding = .utf16BigEndian
        case (_, 0, _, 0), (255, 254, _, _): encoding = .utf16LittleEndian
        default: encoding = .utf8
        }
        guard let source = String(data: data, encoding: encoding),
              let lexer = try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"|[{}\[\]:,]|[^\s{}\[\]:,]+"#) else { return false }
        let text = source as NSString
        let tokens = lexer.matches(in: source, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range) }
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

    private static func isInteger(_ token: String) -> Bool {
        guard let first = token.utf8.first, first == 45 || (48...57).contains(first) else { return false }
        let parts = token.split(whereSeparator: { $0 == "e" || $0 == "E" })
        guard let mantissa = parts.first, parts.count <= 2 else { return false }
        let exponent = parts.count == 1 ? 0 : Int(parts[1])
        guard let exponent else { return false }
        let fractionalDigits = mantissa.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        let (places, overflow) = fractionalDigits.subtractingReportingOverflow(exponent)
        guard !overflow else { return false }
        let digits = mantissa.utf8.filter { (48...57).contains($0) }
        return places <= 0 || digits.suffix(places).allSatisfy { $0 == 48 }
    }
}
