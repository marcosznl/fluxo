import AppKit
import Darwin
import IOKit
import SwiftUI

/// Ajustes dos módulos de sistema (guardados no UserDefaults).
enum SystemSettings {
    static let interval = "sistemaIntervalo"        // segundos entre leituras: 1, 2 ou 5
    static let cpuProcesses = "cpuProcessos"        // quantos processos listar
    static let ramProcesses = "ramProcessos"
    static let ramBadge = "ramSelo"                 // "percent" ou "gb"
    static let ssdBadge = "ssdSelo"                 // "usado" ou "livre"

    static var intervalValue: Double {
        let v = UserDefaults.standard.double(forKey: interval)
        return v > 0 ? v : 2
    }
    static func count(_ key: String) -> Int {
        let v = UserDefaults.standard.integer(forKey: key)
        return v > 0 ? v : 6
    }
}

/// CPU, memória e disco do Mac, lidos a cada 2 s para a barra de menus. A lista de
/// processos (a parte mais cara) só é medida com o painel aberto.
@MainActor
final class SystemMonitor: ObservableObject {
    struct TopProcess: Identifiable {
        let id: Int32
        let name: String
        let icon: NSImage?
        let value: Double   // fração de CPU (1 = um núcleo inteiro) ou bytes
    }

    struct CPU {
        var user = 0.0, system = 0.0
        var total: Double { user + system }
    }

    struct Memory {
        var app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0, cached: UInt64 = 0, free: UInt64 = 0
        var used: UInt64 { app + wired + compressed }
    }

    /// Quantas leituras guardar para os gráficos (2 min).
    static let historyLength = 60

    @Published private(set) var cpu: CPU?
    /// Uso de cada núcleo (0…1), na ordem do sistema.
    @Published private(set) var coreUsage: [Double] = []
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var loadAverage: [Double] = []
    @Published private(set) var topCPU: [TopProcess] = []
    @Published private(set) var processCount = 0
    /// Uso da GPU (0…1), do IOAccelerator.
    @Published private(set) var gpuUsage: Double?
    @Published private(set) var thermal = ProcessInfo.processInfo.thermalState
    let chipName: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()


    @Published private(set) var memory = Memory()
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var swapUsed: UInt64 = 0
    @Published private(set) var swapTotal: UInt64 = 0
    /// 1 = normal, 2 = atenção, 4 = crítica (níveis do kernel).
    @Published private(set) var memoryPressure = 1
    @Published private(set) var topMemory: [TopProcess] = []
    /// Bytes por segundo lidos + gravados no disco.
    @Published private(set) var topDisk: [TopProcess] = []

    @Published private(set) var diskFree: Int64?
    @Published private(set) var diskTotal: Int64?
    @Published private(set) var diskReadBps: Double = 0
    @Published private(set) var diskWriteBps: Double = 0

    /// Núcleos de eficiência e de desempenho (Apple Silicon). Os de eficiência vêm primeiro.
    let efficiencyCores = SystemMonitor.sysctlInt("hw.perflevel1.logicalcpu")
    let performanceCores = SystemMonitor.sysctlInt("hw.perflevel0.logicalcpu")

    private var timer: Timer?
    private var lastTicks: [[UInt32]]?
    private var lastDisk: (read: UInt64, write: UInt64, at: Date)?
    private var lastProcTimes: (times: [Int32: UInt64], io: [Int32: UInt64], at: UInt64)?
    private var names: [Int32: (name: String, icon: NSImage?)] = [:]

    /// Painel aberto: mede também os processos.
    private var detailed = false

    func setDetailed(_ on: Bool) {
        guard on != detailed else { return }
        detailed = on
        lastProcTimes = nil
        if on { sampleProcesses() } else { topCPU = []; topMemory = []; topDisk = []; names = [:] }
    }

    func start() {
        guard timer == nil else { return }
        lastTicks = nil
        lastDisk = nil
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: SystemSettings.intervalValue, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Dados de exemplo para os prints do README (`--snapshot`).
    func loadPreview() {
        let n = max(efficiencyCores + performanceCores, 8)
        coreUsage = (0..<n).map { i in [0.22, 0.35, 0.18, 0.41, 0.62, 0.28, 0.75, 0.33, 0.12, 0.47][i % 10] }
        cpu = CPU(user: 0.24, system: 0.09)
        cpuHistory = (0..<Self.historyLength).map { 0.2 + 0.12 * sin(Double($0) / 5) + 0.06 * sin(Double($0) * 1.7) }
        loadAverage = [2.41, 2.18, 1.97]
        processCount = 642
        gpuUsage = 0.18
        thermal = .nominal
        topCPU = [("Safari", 0.42), ("WindowServer", 0.18), ("Xcode", 0.11), ("Música", 0.06),
                  ("Finder", 0.03), ("Mensagens", 0.02)].enumerated().map { previewProcess($0.offset, $0.element) }
        let gb: Double = 1_073_741_824
        memory = Memory(app: UInt64(6.2 * gb), wired: UInt64(2.6 * gb), compressed: UInt64(1.1 * gb),
                        cached: UInt64(4.4 * gb), free: UInt64(1.7 * gb))
        memoryHistory = (0..<Self.historyLength).map { 0.6 + 0.03 * sin(Double($0) / 9) }
        swapUsed = UInt64(0.8 * gb)
        swapTotal = UInt64(2 * gb)
        memoryPressure = 1
        topMemory = [("Safari", 1.9), ("Xcode", 1.4), ("Mensagens", 0.6), ("Música", 0.45),
                     ("Finder", 0.21), ("Notas", 0.18)].enumerated().map { previewProcess($0.offset, ($0.element.0, $0.element.1 * gb)) }
        diskTotal = 494_000_000_000
        diskFree = 187_000_000_000
        diskReadBps = 3_400_000
        diskWriteBps = 1_200_000
        topDisk = [("Fotos", 2_100_000.0), ("Safari", 640_000), ("Spotlight", 380_000), ("Mail", 95_000)]
            .enumerated().map { previewProcess($0.offset, $0.element) }
        updateBadges()
    }

    private func previewProcess(_ i: Int, _ p: (String, Double)) -> TopProcess {
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: [
            "Safari": "com.apple.Safari", "Xcode": "com.apple.dt.Xcode", "Música": "com.apple.Music",
            "Finder": "com.apple.finder", "Mensagens": "com.apple.MobileSMS", "Notas": "com.apple.Notes",
            "Fotos": "com.apple.Photos", "Mail": "com.apple.mail",
        ][p.0] ?? "").map { NSWorkspace.shared.icon(forFile: $0.path) }
        icon?.size = NSSize(width: 14, height: 14)
        return TopProcess(id: Int32(90000 + i), name: p.0, icon: icon, value: p.1)
    }

    /// Aplica um novo intervalo de leitura (ou outro ajuste que mude o selo).
    func settingsChanged() {
        if timer != nil {
            stop()
            start()
        } else {
            updateBadges()
        }
    }

    /// Percentuais já arredondados para os ícones da barra. Fica num objeto à parte para
    /// que as etiquetas só se redesenhem quando o número mostrado muda.
    let badges = SystemBadgeValues()

    private func sample() {
        defer { updateBadges() }
        sampleCPU()
        sampleGPU()
        thermal = ProcessInfo.processInfo.thermalState
        sampleMemory()
        if detailed { sampleProcesses() }
        sampleDisk()
    }

    private func updateBadges() {
        func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
        func gb(_ b: Double) -> String {
            let v = b / 1_073_741_824
            return v < 10 ? v.formatted(.number.precision(.fractionLength(1))) + "G" : "\(Int(v.rounded()))G"
        }
        let d = UserDefaults.standard
        let total = Double(memoryTotal)
        let ram: String? = total > 0
            ? (d.string(forKey: SystemSettings.ramBadge) == "gb" ? gb(Double(memory.used)) : pct(Double(memory.used) / total))
            : nil
        var ssd: String?
        if let free = diskFree, let t = diskTotal, t > 0 {
            ssd = d.string(forKey: SystemSettings.ssdBadge) == "livre"
                ? gb(Double(free) * 1.073741824)   // em GB "de disco" (base 10), como o Finder
                : pct(Double(t - free) / Double(t))
        }
        let new = SystemBadgeValues.Values(cpu: cpu.map { pct($0.total) }, ram: ram, ssd: ssd)
        if badges.values != new { badges.values = new }
    }

    private func push(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    // MARK: CPU

    private func sampleCPU() {
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { loadAverage = load }

        guard let ticks = Self.readCoreTicks() else { return }
        defer { lastTicks = ticks }
        guard let lastTicks, lastTicks.count == ticks.count else { return }
        var sum = CPU(), totalAll = 0.0
        coreUsage = zip(lastTicks, ticks).map { before, now in
            let d = (0..<Int(CPU_STATE_MAX)).map { Double(now[$0] &- before[$0]) }
            let user = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]
            let system = d[Int(CPU_STATE_SYSTEM)]
            let total = user + system + d[Int(CPU_STATE_IDLE)]
            sum.user += user
            sum.system += system
            totalAll += total
            return total > 0 ? (user + system) / total : 0
        }
        guard totalAll > 0 else { return }
        let c = CPU(user: sum.user / totalAll, system: sum.system / totalAll)
        cpu = c
        push(c.total, to: &cpuHistory)
    }

    /// Ticks acumulados (user, system, idle, nice) de cada núcleo.
    nonisolated static func readCoreTicks() -> [[UInt32]]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            (0..<states).map { UInt32(bitPattern: info[core * states + $0]) }
        }
    }

    nonisolated static func sysctlInt(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
    }

    private func sampleGPU() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                              kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let v = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? Int else { continue }
            gpuUsage = Double(v) / 100
            return
        }
    }

    // MARK: Memória

    private func sampleMemory() {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size) == KERN_SUCCESS
            }
        }
        if ok {
            let page = UInt64(vm_kernel_page_size)
            // Mesmas contas do Monitor de Atividade.
            memory = Memory(
                app: (UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)) * page,
                wired: UInt64(stats.wire_count) * page,
                compressed: UInt64(stats.compressor_page_count) * page,
                cached: (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page,
                free: UInt64(stats.free_count) * page)
            push(Double(memory.used) / Double(memoryTotal), to: &memoryHistory)
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapUsed = swap.xsu_used
            swapTotal = swap.xsu_total
        }

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            memoryPressure = Int(level)
        }
    }

    // MARK: Processos

    /// Uma passada por todos os processos dá os que mais usam CPU e memória.
    /// Só aparecem os do usuário; os do sistema exigem root.
    private func sampleProcesses() {
        let capacity = Int(proc_listallpids(nil, 0)) + 32
        var pids = [Int32](repeating: 0, count: capacity)
        let n = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.size)))
        guard n > 0 else { return }
        processCount = n

        let now = mach_absolute_time()
        var times: [Int32: UInt64] = [:]
        var io: [Int32: UInt64] = [:]
        var diskList: [(Int32, Double)] = []
        var cpuList: [(Int32, Double)] = []
        var memList: [(Int32, Double)] = []
        let elapsed = lastProcTimes.map { Double(now - $0.at) }

        for pid in pids.prefix(n) where pid > 0 {
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0
                }
            }
            guard ok else { continue }
            // Tempos de CPU e o relógio vêm na mesma unidade (mach), então a razão dá a fração.
            let t = usage.ri_user_time + usage.ri_system_time
            times[pid] = t
            let bytes = usage.ri_diskio_bytesread &+ usage.ri_diskio_byteswritten
            io[pid] = bytes
            if let elapsed, elapsed > 0, let before = lastProcTimes?.io[pid], bytes > before {
                diskList.append((pid, Double(bytes - before) / (elapsed / Self.cpuTimeScale / 1e9)))
            }
            if let elapsed, elapsed > 0, let before = lastProcTimes?.times[pid], t >= before {
                cpuList.append((pid, Double(t - before) / elapsed * Self.cpuTimeScale))
            }
            if usage.ri_phys_footprint > 0 { memList.append((pid, Double(usage.ri_phys_footprint))) }
        }
        lastProcTimes = (times, io, now)
        names = names.filter { times[$0.key] != nil }

        func top(_ list: [(Int32, Double)], _ limit: Int) -> [TopProcess] {
            list.sorted { $0.1 > $1.1 }.prefix(limit).map { pid, value in
                let n = info(pid)
                return TopProcess(id: pid, name: n.name, icon: n.icon, value: value)
            }
        }
        topCPU = top(cpuList.filter { $0.1 >= 0.001 }, SystemSettings.count(SystemSettings.cpuProcesses))
        topMemory = top(memList, SystemSettings.count(SystemSettings.ramProcesses))
        topDisk = top(diskList.filter { $0.1 >= 1024 }, 6)
    }

    /// ri_user_time vem em nanossegundos; mach_absolute_time em "ticks" (diferentes no Apple Silicon).
    nonisolated static let cpuTimeScale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.denom) / Double(info.numer)
    }()

    /// Nome e ícone do processo, guardados enquanto ele existir (buscar a cada leitura custa caro).
    private func info(_ pid: Int32) -> (name: String, icon: NSImage?) {
        if let cached = names[pid] { return cached }
        let found: (name: String, icon: NSImage?)
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName {
            let icon = app.icon
            icon?.size = NSSize(width: 14, height: 14)
            found = (n, icon)
        } else {
            var buffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buffer, UInt32(buffer.count))
            let n = String(cString: buffer)
            found = (n.isEmpty ? "PID \(pid)" : n, nil)
        }
        names[pid] = found
        return found
    }

    // MARK: Disco

    private func sampleDisk() {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
            diskFree = values.volumeAvailableCapacityForImportantUsage
            diskTotal = values.volumeTotalCapacity.map(Int64.init)
        }

        let now = Date()
        let io = Self.readDiskBytes()
        if let lastDisk {
            let dt = now.timeIntervalSince(lastDisk.at)
            diskReadBps = Double(io.read &- lastDisk.read) / dt
            diskWriteBps = Double(io.write &- lastDisk.write) / dt
        }
        lastDisk = (io.read, io.write, now)
    }

    /// Bytes lidos/escritos desde o boot, somando todos os discos (IOBlockStorageDriver).
    nonisolated static func readDiskBytes() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString,
                                                              kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            read &+= (stats["Bytes (Read)"] as? UInt64) ?? 0
            write &+= (stats["Bytes (Write)"] as? UInt64) ?? 0
        }
        return (read, write)
    }
}

// MARK: - Barra de menus

/// Selo de um item da barra de menus (CPU, RAM ou SSD): rótulo em cima, percentual
/// embaixo. Imagem "template", como o selo do tráfego.
enum SystemBadge {
    private static let small = NSFont.systemFont(ofSize: 7, weight: .semibold)
    private static let value = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    static func image(_ title: String, _ v: String?) -> NSImage {
        let text = v ?? "–"
        // Largura conforme o texto, para caber "10,3G"; no mínimo a de "100%".
        let width = max(26, ceil((text as NSString).size(withAttributes: [.font: value]).width) + 4)
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            let center = NSMutableParagraphStyle()
            center.alignment = .center
            title.draw(in: NSRect(x: 0, y: 11.5, width: width, height: 10),
                       withAttributes: [.font: small, .foregroundColor: NSColor.black, .paragraphStyle: center])
            text.draw(in: NSRect(x: 0, y: 0, width: width, height: 12),
                      withAttributes: [.font: value, .foregroundColor: NSColor.black, .paragraphStyle: center])
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(title) \(text)"
        return image
    }
}

@MainActor
final class SystemBadgeValues: ObservableObject {
    struct Values: Equatable {
        var cpu: String?, ram: String?, ssd: String?
    }
    @Published var values = Values()
}

struct SystemMenuBarLabel: View {
    enum Kind { case cpu, ram, ssd }

    @ObservedObject var badges: SystemBadgeValues
    let kind: Kind

    var body: some View {
        let v = badges.values
        switch kind {
        case .cpu: Image(nsImage: SystemBadge.image("CPU", v.cpu))
        case .ram: Image(nsImage: SystemBadge.image("RAM", v.ram))
        case .ssd: Image(nsImage: SystemBadge.image(
            UserDefaults.standard.string(forKey: SystemSettings.ssdBadge) == "livre" ? "LIVRE" : "SSD", v.ssd))
        }
    }
}

// MARK: - Formatação

enum SysFormat {
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }

    static func rate(_ bps: Double) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false   // "0 KB/s" em vez de "Zero KB/s"
        return f.string(fromByteCount: Int64(bps)) + "/s"
    }
}

/// Título de coluna do painel.
struct ColumnHeader: View {
    let title: String
    let symbol: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: symbol).font(.headline)
            Spacer()
            if let trailing {
                Text(trailing).font(.title3.weight(.semibold)).monospacedDigit()
            }
        }
    }
}

/// Gráfico de área dos últimos 2 minutos (0…100%). Desenhado direto num Canvas,
/// bem mais leve que o Swift Charts para redesenhar a cada 2 s.
struct UsageChart: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Canvas { ctx, size in
                for f in [0.0, 0.5, 1.0] {
                    let y = size.height * (1 - f)
                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(grid, with: .color(.primary.opacity(0.1)), lineWidth: 0.5)
                }
                guard values.count > 1 else { return }
                let step = size.width / CGFloat(SystemMonitor.historyLength - 1)
                let x0 = size.width - step * CGFloat(values.count - 1)
                let points = values.enumerated().map { i, v in
                    CGPoint(x: x0 + step * CGFloat(i), y: size.height * (1 - min(max(v, 0), 1)))
                }
                var line = Path()
                line.addLines(points)
                var area = line
                area.addLine(to: CGPoint(x: points.last!.x, y: size.height))
                area.addLine(to: CGPoint(x: points[0].x, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .color(tint.opacity(0.2)))
                ctx.stroke(line, with: .color(tint), lineWidth: 1.5)
            }
            VStack(alignment: .trailing) {
                Text("100%"); Spacer(); Text("50%"); Spacer(); Text("0%")
            }
            .font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .frame(height: 70)
    }
}

struct ProcessList: View {
    let title: String
    let processes: [SystemMonitor.TopProcess]
    var empty = "Medindo…"
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if processes.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(processes) { p in
                HStack(spacing: 6) {
                    Group {
                        if let icon = p.icon {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: "gearshape").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 14, height: 14)
                    Text(p.name).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Text(format(p.value)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .module()
    }
}

// MARK: - Coluna CPU

struct CPUColumn: View {
    @EnvironmentObject var system: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ColumnHeader(title: "CPU", symbol: "cpu", trailing: system.cpu.map { SysFormat.percent($0.total) })

            VStack(alignment: .leading, spacing: 8) {
                UsageChart(values: system.cpuHistory, tint: .green)
                HStack {
                    stat("Usuário", system.cpu.map { SysFormat.percent($0.user) }, .green)
                    stat("Sistema", system.cpu.map { SysFormat.percent($0.system) }, .red)
                    stat("Livre", system.cpu.map { SysFormat.percent(1 - $0.total) }, .secondary)
                }
            }
            .module()

            VStack(alignment: .leading, spacing: 6) {
                Text("Núcleos").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                coreBars
            }
            .module()

            VStack(alignment: .leading, spacing: 4) {
                if system.loadAverage.count == 3 {
                    row("Carga média (1, 5, 15 min)",
                        system.loadAverage.map { $0.formatted(.number.precision(.fractionLength(2))) }
                            .joined(separator: "  "))
                }
                row("Processos", "\(system.processCount)")
                row("Ligado há", uptime)
                if !system.chipName.isEmpty { row("Chip", system.chipName) }
                row("Núcleos", system.efficiencyCores > 0
                    ? "\(system.performanceCores) desempenho + \(system.efficiencyCores) eficiência"
                    : "\(system.coreUsage.count)")
                row("GPU", system.gpuUsage.map(SysFormat.percent) ?? "—")
                row("Temperatura", thermalText)
            }
            .font(.caption)
            .module()

            ProcessList(title: "Mais usando CPU", processes: system.topCPU) { SysFormat.percent($0) }
        }
    }

    @ViewBuilder private var coreBars: some View {
        let cores = system.coreUsage
        let e = system.efficiencyCores
        if cores.isEmpty {
            Text("Medindo…").font(.caption).foregroundStyle(.secondary)
        } else if e > 0, e < cores.count {
            coreGroup("Eficiência", Array(cores.prefix(e)), .teal)
            coreGroup("Desempenho", Array(cores.dropFirst(e)), .green)
        } else {
            coreGroup(nil, cores, .green)
        }
    }

    private func coreGroup(_ title: String?, _ cores: [Double], _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title { Text("\(title) · \(cores.count)").font(.caption2).foregroundStyle(.secondary) }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(cores.indices, id: \.self) { i in
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(tint.gradient)
                                .frame(height: max(2, geo.size.height * cores[i]))
                        }
                    }
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 2))
                    .help(SysFormat.percent(cores[i]))
                }
            }
            .frame(height: 34)
        }
    }

    private func stat(_ title: String, _ value: String?, _ tint: some ShapeStyle) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(tint)
            Text(value ?? "—").font(.callout.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private var thermalText: String {
        switch system.thermal {
        case .nominal: "normal"
        case .fair: "morna"
        case .serious: "quente (reduzindo velocidade)"
        case .critical: "crítica"
        @unknown default: "—"
        }
    }

    private var uptime: String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: ProcessInfo.processInfo.systemUptime) ?? "—"
    }
}

// MARK: - Coluna Memória (+ disco)

struct MemoryColumn: View {
    @EnvironmentObject var system: SystemMonitor

    var body: some View {
        let m = system.memory
        let total = Double(system.memoryTotal)
        VStack(alignment: .leading, spacing: 12) {
            ColumnHeader(title: "Memória", symbol: "memorychip",
                         trailing: total > 0 ? SysFormat.percent(Double(m.used) / total) : nil)

            VStack(alignment: .leading, spacing: 8) {
                UsageChart(values: system.memoryHistory, tint: pressureColor)
                HStack {
                    Text("\(SysFormat.bytes(m.used)) de \(SysFormat.bytes(system.memoryTotal))")
                        .monospacedDigit()
                    Spacer()
                    Label("Pressão \(pressureText)", systemImage: "circle.fill")
                        .labelStyle(CompactLabel(tint: pressureColor))
                }
                .font(.caption)
            }
            .module()

            VStack(alignment: .leading, spacing: 6) {
                breakdownBar(m)
                part("Apps", m.app, .blue)
                part("Fixa (sistema)", m.wired, .orange)
                part("Comprimida", m.compressed, .purple)
                part("Em cache", m.cached, .gray)
                part("Livre", m.free, .secondary.opacity(0.4))
                Divider()
                HStack {
                    Text("Swap").foregroundStyle(.secondary)
                    Spacer()
                    Text(system.swapTotal > 0
                         ? "\(SysFormat.bytes(system.swapUsed)) de \(SysFormat.bytes(system.swapTotal))"
                         : "—").monospacedDigit()
                }
                .font(.caption)
            }
            .module()

            ProcessList(title: "Mais usando memória", processes: system.topMemory) {
                SysFormat.bytes(UInt64($0))
            }
        }
    }


    private func breakdownBar(_ m: SystemMonitor.Memory) -> some View {
        let parts: [(UInt64, Color)] = [(m.app, .blue), (m.wired, .orange), (m.compressed, .purple), (m.cached, .gray)]
        let total = max(Double(system.memoryTotal), 1)
        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(parts.indices, id: \.self) { i in
                    parts[i].1.frame(width: max(0, geo.size.width * Double(parts[i].0) / total))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func part(_ title: String, _ bytes: UInt64, _ tint: some ShapeStyle) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(SysFormat.bytes(bytes)).monospacedDigit()
        }
        .font(.caption)
    }

    private var pressureText: String {
        switch system.memoryPressure {
        case 4: "crítica"
        case 2: "alta"
        default: "normal"
        }
    }

    private var pressureColor: Color {
        switch system.memoryPressure {
        case 4: .red
        case 2: .yellow
        default: .blue
        }
    }
}

struct DiskColumn: View {
    @EnvironmentObject var system: SystemMonitor

    var body: some View {
        let used: Double? = {
            guard let free = system.diskFree, let t = system.diskTotal, t > 0 else { return nil }
            return Double(t - free) / Double(t)
        }()
        VStack(alignment: .leading, spacing: 12) {
            ColumnHeader(title: "Disco", symbol: "internaldrive", trailing: used.map(SysFormat.percent))
            DiskBlock()
            StorageCategories(usedBytes: system.diskTotal.flatMap { t in system.diskFree.map { t - $0 } })
            ProcessList(title: "Mais usando o disco agora", processes: system.topDisk,
                        empty: "Nenhum app lendo ou gravando.") { SysFormat.rate($0) }
        }
    }
}

struct DiskBlock: View {
    @EnvironmentObject var system: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Disco", systemImage: "internaldrive").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let free = system.diskFree {
                    Text("\(SysFormat.bytes(UInt64(free))) livres").font(.caption).monospacedDigit()
                }
            }
            if let free = system.diskFree, let total = system.diskTotal, total > 0 {
                ProgressView(value: Double(total - free) / Double(total)).tint(.orange)
            }
            HStack {
                Label(SysFormat.rate(system.diskReadBps), systemImage: "arrow.down.doc")
                Spacer()
                Label(SysFormat.rate(system.diskWriteBps), systemImage: "arrow.up.doc")
            }
            .font(.caption2).foregroundStyle(.secondary)
            .help("Leitura e escrita no disco agora")
        }
        .module()
    }
}

// MARK: - Armazenamento por categoria

/// O que ocupa o SSD, por categoria, como em Ajustes do Sistema › Geral › Armazenamento.
/// Somar o tamanho de pastas grandes leva alguns segundos, então roda em segundo plano
/// e o resultado vale por 10 minutos.
@MainActor
final class StorageScanner: ObservableObject {
    struct Category: Identifiable {
        let id: String
        let symbol: String
        let color: Color
        var bytes: Int64
    }

    static let shared = StorageScanner()

    @Published private(set) var categories: [Category] = []
    @Published private(set) var scanning = false
    private var scannedAt: Date?

    nonisolated private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Pastas de cada categoria. As do Mail, Mensagens e Lixo só são lidas com
    /// "Acesso Total ao Disco"; sem ele, ficam somadas em "Sistema e outros".
    nonisolated private static let definitions: [(String, String, Color, [String])] = [
        ("Apps", "square.grid.2x2", .blue, ["/Applications", "~/Applications"]),
        ("Documentos", "doc", .orange, ["~/Documents", "~/Desktop", "~/Downloads"]),
        ("Fotos", "photo", .pink, ["~/Pictures"]),
        ("Música", "music.note", .red, ["~/Music"]),
        ("Filmes", "film", .purple, ["~/Movies"]),
        ("iCloud Drive", "icloud", .cyan, ["~/Library/Mobile Documents"]),
        ("Mail", "envelope", .indigo, ["~/Library/Mail"]),
        ("Mensagens", "message", .green, ["~/Library/Messages"]),
        ("Desenvolvedor", "hammer", .brown, ["~/Library/Developer"]),
        ("Lixo", "trash", .gray, ["~/.Trash"]),
    ]

    func refreshIfStale() { refresh(force: false) }

    /// Dados de exemplo para os prints do README (`--snapshot`).
    func loadPreview() {
        let gb: Int64 = 1_000_000_000
        categories = [
            Category(id: "Apps", symbol: "square.grid.2x2", color: .blue, bytes: 58 * gb),
            Category(id: "Documentos", symbol: "doc", color: .orange, bytes: 41 * gb),
            Category(id: "Fotos", symbol: "photo", color: .pink, bytes: 36 * gb),
            Category(id: "Desenvolvedor", symbol: "hammer", color: .brown, bytes: 24 * gb),
            Category(id: "iCloud Drive", symbol: "icloud", color: .cyan, bytes: 12 * gb),
            Category(id: "Música", symbol: "music.note", color: .red, bytes: 7 * gb),
            Category(id: "Mail", symbol: "envelope", color: .indigo, bytes: 3 * gb),
        ]
        scannedAt = .now
    }

    func refresh(force: Bool) {
        guard !scanning else { return }
        if !force, let scannedAt, Date.now.timeIntervalSince(scannedAt) < 600 { return }
        scanning = true
        Task.detached(priority: .utility) {
            let result = Self.definitions.map { name, symbol, color, paths in
                Category(id: name, symbol: symbol, color: color,
                         bytes: paths.reduce(0) { $0 + Self.size(of: Self.expand($1)) })
            }
            await MainActor.run {
                self.categories = result.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
                self.scannedAt = .now
                self.scanning = false
            }
        }
    }

    nonisolated private static func expand(_ path: String) -> URL {
        path.hasPrefix("~/")
            ? home.appendingPathComponent(String(path.dropFirst(2)))
            : URL(fileURLWithPath: path)
    }

    /// Espaço ocupado de verdade (blocos alocados), sem seguir links nem entrar em pacotes de outros volumes.
    nonisolated static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                           options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

struct StorageCategories: View {
    @ObservedObject private var scanner = StorageScanner.shared
    /// Espaço usado no volume, para calcular "Sistema e outros".
    let usedBytes: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("O que está ocupando").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if scanner.scanning { ProgressView().controlSize(.mini) }
            }
            if scanner.categories.isEmpty {
                Text("Calculando…").font(.caption).foregroundStyle(.secondary)
            } else {
                let rows = rowsWithSystem
                let maxBytes = Double(rows.map(\.bytes).max() ?? 1)
                ForEach(rows) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: c.symbol).foregroundStyle(c.color).frame(width: 14)
                            Text(c.id)
                            Spacer()
                            Text(SysFormat.bytes(UInt64(c.bytes))).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        GeometryReader { geo in
                            Capsule().fill(c.color.gradient)
                                .frame(width: max(2, geo.size.width * Double(c.bytes) / maxBytes))
                        }
                        .frame(height: 3)
                    }
                }
            }
        }
        .module()
        .onAppear { scanner.refreshIfStale() }
    }

    /// As categorias + "Sistema e outros" (o que sobra do espaço usado), em ordem de tamanho.
    private var rowsWithSystem: [StorageScanner.Category] {
        var rows = scanner.categories
        if let usedBytes {
            let rest = usedBytes - rows.reduce(0) { $0 + $1.bytes }
            if rest > 0 {
                rows.append(.init(id: "Sistema e outros", symbol: "gearshape", color: .secondary, bytes: rest))
            }
        }
        return rows.sorted { $0.bytes > $1.bytes }
    }
}

// MARK: - Engrenagem dos painéis de sistema

/// Rodapé de um painel de sistema: o rótulo à esquerda e a engrenagem com os ajustes dele.
struct ModuleFooter<Settings: View>: View {
    let caption: String
    @ViewBuilder let settings: () -> Settings

    var body: some View {
        HStack {
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Menu {
                settings()
                Divider()
                Button("Sair do Fluxo") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Ajustes")
        }
    }
}

/// Ajustes comuns aos três: intervalo de leitura e mostrar o ícone na barra.
struct SystemCommonSettings: View {
    @EnvironmentObject var system: SystemMonitor
    @AppStorage(SystemSettings.interval) private var interval = 2.0
    let showKey: String
    @AppStorage private var show: Bool

    init(showKey: String) {
        self.showKey = showKey
        _show = AppStorage(wrappedValue: true, showKey)
    }

    var body: some View {
        Picker("Atualizar a cada", selection: $interval) {
            Text("1 segundo").tag(1.0)
            Text("2 segundos").tag(2.0)
            Text("5 segundos").tag(5.0)
        }
        .onChange(of: interval) { _, _ in system.settingsChanged() }
        Toggle("Mostrar na barra de menus", isOn: $show)
    }
}

struct CPUSettings: View {
    @AppStorage(SystemSettings.cpuProcesses) private var count = 6

    var body: some View {
        Picker("Processos na lista", selection: $count) {
            ForEach([3, 6, 10], id: \.self) { Text("\($0)").tag($0) }
        }
        SystemCommonSettings(showKey: ModuleKey.cpu)
    }
}

struct RAMSettings: View {
    @EnvironmentObject var system: SystemMonitor
    @AppStorage(SystemSettings.ramProcesses) private var count = 6
    @AppStorage(SystemSettings.ramBadge) private var badge = "percent"

    var body: some View {
        Picker("Ícone mostra", selection: $badge) {
            Text("Percentual usado").tag("percent")
            Text("GB usados").tag("gb")
        }
        .onChange(of: badge) { _, _ in system.settingsChanged() }
        Picker("Processos na lista", selection: $count) {
            ForEach([3, 6, 10], id: \.self) { Text("\($0)").tag($0) }
        }
        SystemCommonSettings(showKey: ModuleKey.ram)
    }
}

struct SSDSettings: View {
    @EnvironmentObject var system: SystemMonitor
    @AppStorage(SystemSettings.ssdBadge) private var badge = "usado"

    var body: some View {
        Picker("Ícone mostra", selection: $badge) {
            Text("Percentual usado").tag("usado")
            Text("GB livres").tag("livre")
        }
        .onChange(of: badge) { _, _ in system.settingsChanged() }
        Button("Recalcular o que está ocupando") { StorageScanner.shared.refresh(force: true) }
        SystemCommonSettings(showKey: ModuleKey.ssd)
    }
}
