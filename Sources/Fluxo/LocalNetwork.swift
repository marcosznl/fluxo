import Darwin
import dnssd
import SwiftUI

/// Aparelhos da rede local, descobertos só com o que o próprio Mac enxerga: um ping em
/// toda a sub-rede (no máximo 254 endereços) e a tabela ARP. Roda a cada 30 s, e só
/// enquanto o painel da rede está aberto.
@MainActor
final class LocalNetworkScanner: ObservableObject {
    struct Device: Identifiable, Equatable {
        var id: String { ip }
        let ip: String
        var mac: String?
        var name: String?
        var pingMs: Double?
        var lastSeen: Date
        var isGateway = false
        var isThisMac = false

        /// MAC "privado" (aleatório), usado por iPhone, Android e Windows para não ser rastreado.
        var hasPrivateMAC: Bool {
            guard let mac, let first = UInt8(mac.prefix(2), radix: 16) else { return false }
            return first & 0x02 != 0
        }

        var online: Bool { Date.now.timeIntervalSince(lastSeen) < 90 }
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var scanning = false
    @Published private(set) var subnet: String?

    private var timer: Timer?
    private var known: [String: Device] = [:]
    private var resolving: Set<String> = []

    func start() {
        guard timer == nil else { return }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scan() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let result = Self.discover()
            await MainActor.run { self.merge(result) }
        }
    }

    private struct Discovery: Sendable {
        var subnet: String?
        var myIP: String?
        var gateway: String?
        var pings: [String: Double] = [:]
        var arp: [String: String] = [:]
        var names: [String: String] = [:]
    }

    private func merge(_ r: Discovery) {
        scanning = false
        subnet = r.subnet
        let now = Date.now
        for ip in Set(r.pings.keys).union(r.arp.keys) {
            var d = known[ip] ?? Device(ip: ip, lastSeen: now)
            d.lastSeen = now
            d.pingMs = r.pings[ip]
            d.mac = r.arp[ip] ?? d.mac
            if let name = r.names[ip] { d.name = name }
            d.isGateway = ip == r.gateway
            d.isThisMac = ip == r.myIP
            known[ip] = d
        }
        // Quem não aparece há 10 min sai da lista.
        known = known.filter { now.timeIntervalSince($0.value.lastSeen) < 600 }
        for ip in known.keys where known[ip]?.name == nil && !resolving.contains(ip) { resolveName(ip) }
        publish()
    }

    private func publish() {
        devices = known.values.sorted { a, b in
            if a.isGateway != b.isGateway { return a.isGateway }
            if a.isThisMac != b.isThisMac { return a.isThisMac }
            return Self.ipValue(a.ip) < Self.ipValue(b.ip)
        }
    }

    private func resolveName(_ ip: String) {
        resolving.insert(ip)
        Task.detached(priority: .utility) {
            let name = Self.reverseName(ip)
            await MainActor.run {
                self.resolving.remove(ip)
                guard let name, self.known[ip] != nil else { return }
                self.known[ip]?.name = name
                self.publish()
            }
        }
    }

    /// `Fluxo --rede-local`: faz uma varredura e imprime o que achou.
    static func selfTest() {
        let r = discover()
        print("Sub-rede \(r.subnet ?? "?"), este Mac \(r.myIP ?? "?"), roteador \(r.gateway ?? "?")")
        for ip in Set(r.pings.keys).union(r.arp.keys).sorted(by: { ipValue($0) < ipValue($1) }) {
            let ping = r.pings[ip].map { String(format: "%.1f ms", $0) } ?? "sem ping"
            print("  \(ip)\t\(r.arp[ip] ?? "—")\t\(ping)\t\(r.names[ip] ?? reverseName(ip) ?? "")")
        }
        exit(0)
    }

    // MARK: Descoberta (fora da main thread)

    nonisolated private static func discover() -> Discovery {
        var r = Discovery()
        guard let iface = DefaultRoute.interface(), let net = ipv4(of: iface) else { return r }
        r.myIP = string(net.addr)
        r.gateway = defaultGateway()
        let mask = UInt32(bigEndian: net.mask)
        let base = UInt32(bigEndian: net.addr) & mask
        let size = ~mask
        r.subnet = "\(string(base.bigEndian))/\(32 - size.nonzeroBitCount)"
        // Sub-redes maiores que /24 ficam limitadas aos 254 vizinhos mais próximos.
        let hostBase = size > 255 ? (UInt32(bigEndian: net.addr) & 0xFFFF_FF00) : base
        let count = min(size, 255)
        let hosts = (1..<count).map { (hostBase + $0).bigEndian }
        // A 1ª rodada descobre quem responde (e paga a resolução ARP); a 2ª mede o ping de verdade.
        let alive = ping(hosts, timeout: 1.5)
        let again = ping(hosts.filter { alive[string($0)] != nil }, timeout: 1)
        r.pings = alive.merging(again) { _, new in new }
        // Só vizinhos da própria sub-rede (fica de fora multicast, como 224.0.0.251 do mDNS).
        r.arp = arpTable(interface: iface).filter { ip, _ in
            ipValue(ip) & mask == base && ipValue(ip) != base | size
        }
        let found = Array(Set(r.pings.keys).union(r.arp.keys))
        // SSDP (TVs, Chromecast, roteador) primeiro; o mDNS (Apple, impressoras) tem prioridade.
        r.names = ssdpNames().merging(mdnsNames(found)) { _, mdns in mdns }
        return r
    }

    nonisolated static func ipValue(_ ip: String) -> UInt32 {
        var a = in_addr()
        inet_pton(AF_INET, ip, &a)
        return UInt32(bigEndian: a.s_addr)
    }

    nonisolated static func string(_ addr: in_addr_t) -> String {
        var a = in_addr(s_addr: addr)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }

    nonisolated private static func ipv4(of iface: String) -> (addr: in_addr_t, mask: in_addr_t)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var p = list
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard String(cString: i.pointee.ifa_name) == iface,
                  let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET),
                  let m = i.pointee.ifa_netmask else { continue }
            let addr = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            return (addr, mask)
        }
        return nil
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out
    }

    nonisolated private static func defaultGateway() -> String? {
        run("/sbin/route", ["-n", "get", "default"]).firstMatch(of: /gateway:\s*(\S+)/).map { String($0.1) }
    }

    /// IP → MAC dos vizinhos que o Mac já conhece (a tabela ARP, lida do kernel).
    nonisolated private static func arpTable(interface: String) -> [String: String] {
        let ifIndex = if_nametoindex(interface)
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var len = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &len, nil, 0) == 0 else { return [:] }

        var result: [String: String] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= len {
                let rtm = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                guard rtm.rtm_msglen > 0 else { break }
                defer { offset += Int(rtm.rtm_msglen) }
                // Depois do cabeçalho: o endereço IP (sockaddr_in) e o de enlace (sockaddr_dl).
                let sinOffset = offset + MemoryLayout<rt_msghdr>.size
                let sin = raw.loadUnaligned(fromByteOffset: sinOffset, as: sockaddr_in.self)
                let sinLen = Int(sin.sin_len) > 0 ? (Int(sin.sin_len) + 3) & ~3 : 4
                let sdlOffset = sinOffset + sinLen
                guard sdlOffset + 8 <= offset + Int(rtm.rtm_msglen) else { continue }
                let sdl = raw.loadUnaligned(fromByteOffset: sdlOffset, as: sockaddr_dl.self)
                guard sdl.sdl_family == UInt8(AF_LINK), UInt32(sdl.sdl_index) == ifIndex,
                      sdl.sdl_alen == 6 else { continue }
                let macStart = sdlOffset + 8 + Int(sdl.sdl_nlen)
                let mac = (0..<6).map { String(format: "%02x", raw[macStart + $0]) }.joined(separator: ":")
                if mac == "ff:ff:ff:ff:ff:ff" { continue }
                result[string(sin.sin_addr.s_addr)] = mac
            }
        }
        return result
    }

    // MARK: Nomes

    /// "iPhone-de-Marcos.local." → "iPhone de Marcos".
    nonisolated static func friendly(_ host: String) -> String {
        var n = host
        if n.hasSuffix(".") { n.removeLast() }
        if n.hasSuffix(".local") {
            n = String(n.dropLast(6)).replacingOccurrences(of: "-", with: " ")
        }
        return n
    }

    /// Pergunta "quem é você?" por mDNS (DNS reverso no .local) a todos os IPs ao mesmo tempo.
    /// Respondem Macs, iPhones, iPads, HomePods, impressoras e vários aparelhos com Bonjour.
    nonisolated static func mdnsNames(_ ips: [String], timeout: TimeInterval = 2) -> [String: String] {
        let box = MDNSBox()
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        var refs: [(DNSServiceRef, String)] = []
        defer { refs.forEach { DNSServiceRefDeallocate($0.0) } }

        let callback: DNSServiceQueryRecordReply = { _, _, _, err, fullname, _, _, len, rdata, _, context in
            guard err == kDNSServiceErr_NoError, let rdata, let fullname, let context else { return }
            let box = Unmanaged<MDNSBox>.fromOpaque(context).takeUnretainedValue()
            // fullname: "64.1.168.192.in-addr.arpa." → IP de trás para frente.
            let parts = String(cString: fullname).split(separator: ".").prefix(4).reversed()
            let ip = parts.joined(separator: ".")
            if let name = LocalNetworkScanner.parseDNSName(rdata.assumingMemoryBound(to: UInt8.self), Int(len)) {
                box.names[ip] = LocalNetworkScanner.friendly(name)
            }
        }
        for ip in ips {
            let reverse = ip.split(separator: ".").reversed().joined(separator: ".") + ".in-addr.arpa."
            var ref: DNSServiceRef?
            let err = DNSServiceQueryRecord(&ref, DNSServiceFlags(kDNSServiceFlagsForceMulticast), 0, reverse,
                                            UInt16(kDNSServiceType_PTR), UInt16(kDNSServiceClass_IN),
                                            callback, ctx)
            if err == kDNSServiceErr_NoError, let ref { refs.append((ref, ip)) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, box.names.count < refs.count {
            var fds = refs.map { pollfd(fd: DNSServiceRefSockFD($0.0), events: Int16(POLLIN), revents: 0) }
            let left = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&fds, nfds_t(fds.count), left) > 0 else { break }
            for (i, fd) in fds.enumerated() where fd.revents & Int16(POLLIN) != 0 {
                DNSServiceProcessResult(refs[i].0)
            }
        }
        return box.names
    }

    /// Lê um nome DNS em formato de rótulos ("\x06iPhone\x05local\x00").
    nonisolated static func parseDNSName(_ p: UnsafePointer<UInt8>, _ len: Int) -> String? {
        var labels: [String] = []
        var i = 0
        while i < len {
            let n = Int(p[i])
            if n == 0 { break }
            guard n < 64, i + 1 + n <= len else { return nil }
            labels.append(String(decoding: UnsafeBufferPointer(start: p + i + 1, count: n), as: UTF8.self))
            i += 1 + n
        }
        return labels.isEmpty ? nil : labels.joined(separator: ".")
    }

    /// Pergunta por SSDP (UPnP) quem está na rede e lê o "friendlyName" da descrição de cada
    /// aparelho. Respondem TVs, Chromecast, consoles, caixas de som e roteadores.
    nonisolated static func ssdpNames(timeout: TimeInterval = 2) -> [String: String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: ssdp:all\r\n\r\n"
        var to = sockaddr_in()
        to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &to.sin_addr)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, msg, msg.utf8.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var locations: [String: String] = [:]   // IP → URL da descrição
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(max(1, deadline.timeIntervalSinceNow * 1000))) > 0 else { break }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            let text = String(decoding: buffer.prefix(n), as: UTF8.self)
            let ip = string(from.sin_addr.s_addr)
            if locations[ip] == nil, let m = text.firstMatch(of: /(?i)\r\nlocation:\s*(\S+)/) {
                locations[ip] = String(m.1)
            }
        }

        // Baixa as descrições em paralelo (são XMLs pequenos na própria rede).
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var names: [String: String] = [:]
        }
        let box = Box()
        let group = DispatchGroup()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)
        for (ip, location) in locations {
            guard let url = URL(string: location) else { continue }
            group.enter()
            session.dataTask(with: url) { data, _, _ in
                defer { group.leave() }
                guard let data, let xml = String(data: data, encoding: .utf8),
                      let m = xml.firstMatch(of: /<friendlyName>([^<]+)<\/friendlyName>/) else { return }
                let name = String(m.1).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                box.lock.lock(); box.names[ip] = name; box.lock.unlock()
            }.resume()
        }
        _ = group.wait(timeout: .now() + 3)
        session.invalidateAndCancel()
        return box.names
    }

    /// Nome pelo DNS reverso / mDNS (ex.: "iPhone-de-Marcos.local"), quando o aparelho responde.
    nonisolated private static func reverseName(_ ip: String) -> String? {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, ip, &sa.sin_addr)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count),
                            nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        let name = String(cString: host)
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    /// Envia um ping (ICMP echo) para cada endereço por um único socket sem privilégio
    /// e devolve o tempo de resposta (ms) de quem respondeu.
    nonisolated static func ping(_ hosts: [in_addr_t], timeout: TimeInterval) -> [String: Double] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        let ident = UInt16(truncatingIfNeeded: getpid())
        var sentAt: [in_addr_t: Date] = [:]

        for (seq, host) in hosts.enumerated() {
            var packet = [UInt8](repeating: 0, count: 16)
            packet[0] = 8   // echo request
            packet[4] = UInt8(ident >> 8); packet[5] = UInt8(ident & 0xFF)
            packet[6] = UInt8((seq >> 8) & 0xFF); packet[7] = UInt8(seq & 0xFF)
            let sum = checksum(packet)
            packet[2] = UInt8(sum >> 8); packet[3] = UInt8(sum & 0xFF)
            var to = sockaddr_in()
            to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            to.sin_family = sa_family_t(AF_INET)
            to.sin_addr.s_addr = host
            sentAt[host] = Date()
            _ = withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var replies: [String: Double] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 1500)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&pfd, 1, left) > 0 else { break }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &len)
                }
            }
            guard n > 0 else { continue }
            // A resposta vem com o cabeçalho IP na frente.
            let ipHeader = Int(buffer[0] & 0x0F) * 4
            guard n > ipHeader, buffer[ipHeader] == 0,   // echo reply
                  let sent = sentAt[from.sin_addr.s_addr] else { continue }
            let ip = string(from.sin_addr.s_addr)
            if replies[ip] == nil { replies[ip] = Date().timeIntervalSince(sent) * 1000 }
        }
        return replies
    }

    nonisolated private static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for i in stride(from: 0, to: data.count, by: 2) {
            sum += UInt32(data[i]) << 8 | UInt32(i + 1 < data.count ? data[i + 1] : 0)
        }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}

// MARK: - Coluna do painel

struct LocalNetworkColumn: View {
    @EnvironmentObject var scanner: LocalNetworkScanner

    var body: some View {
        let online = scanner.devices.filter(\.online).count
        VStack(alignment: .leading, spacing: 12) {
            ColumnHeader(title: "Rede local", symbol: "wifi.router",
                         trailing: scanner.devices.isEmpty ? nil : "\(online)")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(scanner.subnet ?? "Procurando…")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if scanner.scanning { ProgressView().controlSize(.mini) }
                }
                if scanner.devices.isEmpty {
                    Text(scanner.scanning ? "Procurando aparelhos…" : "Nenhum aparelho encontrado.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(scanner.devices) { d in
                            DeviceRow(device: d)
                            if d.id != scanner.devices.last?.id { Divider() }
                        }
                    }
                    .padding(.trailing, 8)   // espaço para a barra de rolagem
                }
                .scrollIndicators(.automatic)
                .frame(minHeight: 120, maxHeight: .infinity)
            }
            .module(fill: true)
        }
    }
}

private struct DeviceRow: View {
    let device: LocalNetworkScanner.Device

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(device.online ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 4) {
                    Circle().fill(device.online ? .green : .gray).frame(width: 6, height: 6)
                    Text(device.online ? "online" : "offline").font(.caption2).foregroundStyle(.secondary)
                }
                Text(ping).font(.caption).monospacedDigit()
            }
        }
        .font(.caption)
        .help(device.mac.map { "MAC \($0)" } ?? device.ip)
    }

    private var symbol: String {
        if device.isGateway { return "wifi.router" }
        if device.isThisMac { return "laptopcomputer" }
        let n = device.name?.lowercased() ?? ""
        if n.contains("iphone") { return "iphone" }
        if n.contains("ipad") { return "ipad" }
        if n.contains("macbook") || n.contains("imac") || n.contains("mac") { return "desktopcomputer" }
        if n.contains("tv") || n.contains("lg") || n.contains("samsung") { return "tv" }
        if device.name == nil, device.hasPrivateMAC { return "iphone.gen3" }
        return "network"
    }

    private var title: String {
        if device.isGateway { return device.name ?? "Roteador" }
        if device.isThisMac { return "Este Mac" }
        if let name = device.name { return name }
        return device.hasPrivateMAC ? "MAC privado (celular/tablet?)" : "Sem nome"
    }

    private var subtitle: String {
        [device.ip, device.mac]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var ping: String {
        if device.isThisMac { return "—" }
        guard let ms = device.pingMs else { return "sem ping" }
        return ms < 1 ? "<1 ms" : "\(Int(ms.rounded())) ms"
    }
}

/// Onde as respostas do mDNS são juntadas (o callback em C não pode capturar variáveis).
private final class MDNSBox {
    var names: [String: String] = [:]
}
