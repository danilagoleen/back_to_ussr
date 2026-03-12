import Foundation

struct SubscriptionParser {
    func decodeSubscription(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        if trimmed.contains("vless://") {
            return trimmed
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map(String.init)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.hasPrefix("vless://") }
        }

        let compact = trimmed.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        let normal = compact
        let urlsafeToStd = compact.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let candidates = [normal, urlsafeToStd].flatMap { [$0, $0 + "=", $0 + "==", $0 + "==="] }

        for candidate in candidates {
            guard let data = Data(base64Encoded: candidate, options: [.ignoreUnknownCharacters]),
                  let decoded = String(data: data, encoding: .utf8) else {
                continue
            }

            let lines = decoded
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map(String.init)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.hasPrefix("vless://") }
            if !lines.isEmpty {
                return lines
            }
        }

        return []
    }

    func parseVless(_ uri: String, sourceURL: String) -> VlessNode? {
        guard uri.lowercased().hasPrefix("vless://") else { return nil }
        let body = String(uri.dropFirst("vless://".count))
        guard let at = body.firstIndex(of: "@") else { return nil }

        let user = String(body[..<at])
        let hostAndRest = String(body[body.index(after: at)...])
        let fragmentSplit = hostAndRest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let noFragment = String(fragmentSplit[0])
        let name = fragmentSplit.count > 1
            ? (String(fragmentSplit[1]).removingPercentEncoding ?? String(fragmentSplit[1]))
            : ""

        let querySplit = noFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let hostPort = String(querySplit[0])
        let query = querySplit.count > 1 ? String(querySplit[1]) : ""

        guard let colon = hostPort.lastIndex(of: ":") else { return nil }
        let host = String(hostPort[..<colon])
        guard let port = Int(String(hostPort[hostPort.index(after: colon)...])) else { return nil }

        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            params[key] = value
        }

        return VlessNode(
            name: name.isEmpty ? "\(host):\(port)" : name,
            raw: uri,
            uuid: user,
            server: host,
            port: port,
            sni: params["sni"] ?? "",
            pbk: params["pbk"] ?? "",
            sid: params["sid"] ?? "",
            fp: params["fp"] ?? "chrome",
            flow: params["flow"] ?? "",
            sourceURL: sourceURL
        )
    }
}
