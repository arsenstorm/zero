import Darwin
import Foundation
import Observation

/// One process as the memory notice weighs it: where it runs from, its parent, and its physical footprint (top's MEM).
public struct ProcessSample: Equatable, Sendable {
    public let pid: pid_t
    public let ppid: pid_t
    public let path: String
    public let memory: UInt64

    public init(pid: pid_t, ppid: pid_t, path: String, memory: UInt64) {
        self.pid = pid; self.ppid = ppid; self.path = path; self.memory = memory
    }
}

/// What uses memory, by app: a browser with all its helpers, a VM, the simulator, Zero's tasks (every agent CLI with
/// its MCP servers and commands), or a lone program by its name.
public struct MemoryGroup: Equatable, Sendable, Identifiable {
    public let name: String
    public let memory: UInt64
    public let processes: Int
    /// Zero's own tasks: what the user can stop from Zero (Task cost, Left running).
    public let tasks: Bool
    public var id: String { name }

    public static let tasksName = "Zero's tasks"

    /// Every process into its group, heaviest first.
    public static func group(_ samples: [ProcessSample]) -> [MemoryGroup] {
        let byPid = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var totals: [String: (memory: UInt64, count: Int)] = [:]
        for sample in samples {
            let name = name(of: sample, in: byPid)
            totals[name, default: (0, 0)].memory += sample.memory
            totals[name, default: (0, 0)].count += 1
        }
        return totals.map { MemoryGroup(name: $0.key, memory: $0.value.memory, processes: $0.value.count, tasks: $0.key == tasksName) }
            .sorted { $0.memory != $1.memory ? $0.memory > $1.memory : $0.name < $1.name }
    }

    /// Under zerod (not zerod itself): a task's. Else the simulator's, else its outermost app's
    /// (Chrome's helpers are apps inside Chrome.app), else its program's name.
    static func name(of sample: ProcessSample, in byPid: [pid_t: ProcessSample]) -> String {
        var parent = byPid[sample.ppid]
        var seen: Set<pid_t> = [sample.pid]
        while let p = parent, seen.insert(p.pid).inserted {
            if p.path.hasSuffix("/zerod") { return tasksName }
            parent = byPid[p.ppid]
        }
        if sample.path.contains("CoreSimulator") || sample.path.contains("/Simulator.app/") { return "Simulator" }
        if let app = sample.path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
        return sample.path.split(separator: "/").last.map(String.init) ?? sample.path
    }
}

/// The machine's memory while it's short: how short, and what holds it.
public struct MemoryShortage: Equatable, Sendable {
    public let critical: Bool
    /// Physical memory the compressor occupies, and swap used of its total, in bytes.
    public let compressed: UInt64
    public let swapUsed: UInt64
    public let swapTotal: UInt64
    public let groups: [MemoryGroup]
}

/// Watches for memory running short, at about no cost while it isn't: the kernel's pressure notifications, and every
/// 30 s two counters (the kernel can call it normal while most of memory is compressed and swap is nearly full).
/// Only while it's short does it list processes, every 10 s, to group them. It never stops anything.
@MainActor @Observable
public final class MemoryWatch {
    public static let shared = MemoryWatch()

    /// Nil while memory is fine.
    public private(set) var shortage: MemoryShortage?

    @ObservationIgnored private let queue = DispatchQueue(label: "zero.memory", qos: .utility)
    @ObservationIgnored private var pressure: DispatchSourceMemoryPressure?
    /// Rescheduled on the watch's queue alone, after init.
    @ObservationIgnored nonisolated(unsafe) private var timer: DispatchSourceTimer?

    private init() {
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        pressure.setEventHandler { [weak self] in self?.check() }
        pressure.activate()
        self.pressure = pressure
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.schedule(deadline: .now(), repeating: .seconds(30), leeway: .seconds(10))
        timer.activate()
        self.timer = timer
    }

    /// On the watch's queue.
    nonisolated private func check() {
        let counters = Self.counters()
        let short = Self.isShort(
            level: counters.level, compressed: counters.compressed, swapUsed: counters.swapUsed,
            swapTotal: counters.swapTotal, ram: ProcessInfo.processInfo.physicalMemory)
        let shortage =
            short
            ? MemoryShortage(
                critical: counters.level >= 4, compressed: counters.compressed, swapUsed: counters.swapUsed,
                swapTotal: counters.swapTotal, groups: MemoryGroup.group(Self.processes()))
            : nil
        // Every 10 s while short, to keep the groups current; back to 30 s once it's fine.
        timer?.schedule(deadline: .now() + (short ? 10 : 30), repeating: short ? 10 : 30, leeway: .seconds(short ? 2 : 10))
        Task { @MainActor in if self.shortage != shortage { self.shortage = shortage } }
    }

    /// Short: the kernel says warning (2) or critical (4), or the compressor holds 40% of memory, or swap is 80%
    /// used and over a gigabyte (as when the Mac lagged with 23 of 48 GB compressed and 4.1 of 5.1 GB swapped).
    public nonisolated static func isShort(level: Int32, compressed: UInt64, swapUsed: UInt64, swapTotal: UInt64, ram: UInt64) -> Bool {
        level >= 2 || compressed * 10 >= ram * 4 || (swapUsed >= 1 << 30 && swapUsed * 10 >= swapTotal * 8)
    }

    nonisolated static func counters() -> (level: Int32, compressed: UInt64, swapUsed: UInt64, swapTotal: UInt64) {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return (level, UInt64(stats.compressor_page_count) * UInt64(vm_kernel_page_size), swap.xsu_used, swap.xsu_total)
    }

    /// The user's processes with their footprints (another user's, such as WindowServer's, can't be read, and are left
    /// out). A few milliseconds for 800 processes.
    nonisolated public static func processes() -> [ProcessSample] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let n = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(max(0, n)).compactMap { pid in
            guard pid > 0 else { return nil }
            var usage = rusage_info_v2()
            let read = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard read == 0, usage.ri_phys_footprint > 0 else { return nil }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            let name = length > 0 ? String(decoding: path.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
            return ProcessSample(pid: pid, ppid: pid_t(info.pbsi_ppid), path: name, memory: usage.ri_phys_footprint)
        }
    }
}
