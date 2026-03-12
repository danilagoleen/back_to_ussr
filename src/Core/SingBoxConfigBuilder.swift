import Foundation

struct SingBoxConfigBuilder {
    func buildRuntimeConfig(node: VlessNode, useFlow: Bool, ports: SingBoxPorts) throws -> Data {
        var outbound: [String: Any] = [
            "type": "vless",
            "tag": "proxy",
            "server": node.server,
            "server_port": node.port,
            "uuid": node.uuid,
            "tls": [
                "enabled": true,
                "server_name": node.sni.isEmpty ? node.server : node.sni,
                "utls": [
                    "enabled": true,
                    "fingerprint": node.fp.isEmpty ? "chrome" : node.fp,
                ],
                "reality": [
                    "enabled": true,
                    "public_key": node.pbk,
                    "short_id": node.sid,
                ],
            ],
        ]

        if useFlow && !node.flow.isEmpty {
            outbound["flow"] = node.flow
        }

        let config: [String: Any] = [
            "log": ["level": "error"],
            "dns": [
                "strategy": "prefer_ipv4",
                "servers": [
                    ["address": "https://1.1.1.1/dns-query", "detour": "proxy"],
                    ["address": "local"],
                ],
            ],
            "inbounds": makeInbounds(ports: ports),
            "outbounds": [
                outbound,
                ["type": "direct", "tag": "direct"],
                ["type": "dns", "tag": "dns-out"],
            ],
            "route": [
                "auto_detect_interface": true,
                "final": "proxy",
                "rules": [
                    [
                        "ip_cidr": [
                            "127.0.0.0/8",
                            "10.0.0.0/8",
                            "172.16.0.0/12",
                            "192.168.0.0/16",
                            "::1/128",
                            "fc00::/7",
                        ],
                        "outbound": "direct",
                    ],
                    [
                        "domain_suffix": [
                            "localhost",
                            "local",
                        ],
                        "outbound": "direct",
                    ],
                    ["protocol": "dns", "outbound": "dns-out"],
                ],
            ],
        ]

        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    func buildDirectConfig(ports: SingBoxPorts) throws -> Data {
        let config: [String: Any] = [
            "log": ["level": "error"],
            "inbounds": makeInbounds(ports: ports),
            "outbounds": [["type": "direct", "tag": "direct"]],
            "route": ["final": "direct"],
        ]

        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    func writeConfig(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private func makeInbounds(ports: SingBoxPorts) -> [[String: Any]] {
        [
            [
                "type": "socks",
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "listen_port": ports.socks,
            ],
            [
                "type": "http",
                "tag": "http-in",
                "listen": "127.0.0.1",
                "listen_port": ports.http,
            ],
        ]
    }
}
