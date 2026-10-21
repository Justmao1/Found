import Foundation

public enum ServerAddress {
    public static func parse(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              validHost(host),
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw APIError.invalidServerAddress("Enter the server origin, for example https://server.local:8443, without a path or login details.")
        }

        // URLComponents reports nil for both absent and overflowing ports, so check the source too.
        let authority = value.components(separatedBy: "://").dropFirst().joined(separator: "://")
            .split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard validPort(in: authority) else {
            throw APIError.invalidServerAddress("The server port must be a number from 1 to 65535.")
        }
        guard scheme == "https" || isLoopback(host) else {
            throw APIError.invalidServerAddress("Use HTTPS for a network server. HTTP is supported only for localhost or a loopback address.")
        }

        components.scheme = scheme
        components.host = host.lowercased()
        components.path = ""
        guard let url = components.url else {
            throw APIError.invalidServerAddress("The server address is invalid.")
        }
        return url
    }

    private static func validPort(in authority: String) -> Bool {
        let suffix: Substring
        if authority.hasPrefix("["), let bracket = authority.firstIndex(of: "]") {
            suffix = authority[authority.index(after: bracket)...]
        } else if let colon = authority.firstIndex(of: ":") {
            suffix = authority[colon...]
        } else {
            return true
        }
        if suffix.isEmpty { return true }
        guard suffix.first == ":" else { return false }
        let digits = suffix.dropFirst()
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(digits) else { return false }
        return (1...65535).contains(port)
    }

    private static func validHost(_ rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.contains(":") {
            return ipv6Groups(host) != nil
        }
        guard !host.isEmpty, !host.contains("%"),
              host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" }) else {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else {
            return false
        }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            return ipv4Octets(host) != nil
        }
        return true
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func isLoopback(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" { return true }
        if let octets = ipv4Octets(host) { return octets.first == 127 }
        return ipv6Groups(host) == [0, 0, 0, 0, 0, 0, 0, 1]
    }

    private static func ipv6Groups(_ host: String) -> [UInt16]? {
        let halves = host.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func parseHalf(_ half: String) -> [UInt16]? {
            if half.isEmpty { return [] }
            let parts = half.split(separator: ":", omittingEmptySubsequences: false)
            var result: [UInt16] = []
            for (index, part) in parts.enumerated() {
                if part.contains(".") {
                    guard index == parts.count - 1, let bytes = ipv4Octets(String(part)) else { return nil }
                    result += [UInt16(bytes[0] * 256 + bytes[1]), UInt16(bytes[2] * 256 + bytes[3])]
                } else {
                    guard (1...4).contains(part.count),
                          part.allSatisfy({ $0.isHexDigit }), let value = UInt16(part, radix: 16) else { return nil }
                    result.append(value)
                }
            }
            return result
        }
        guard let left = parseHalf(halves[0]) else { return nil }
        if halves.count == 1 { return left.count == 8 ? left : nil }
        guard !halves[0].contains("."), let right = parseHalf(halves[1]), left.count + right.count < 8 else { return nil }
        return left + Array(repeating: 0, count: 8 - left.count - right.count) + right
    }
}
