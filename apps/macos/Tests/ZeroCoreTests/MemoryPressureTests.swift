import Foundation
import Testing
@testable import ZeroCore

/// Processes grouped as the notice lists them: a browser's helpers together, a task's CLI with its MCP servers and
/// commands together (but not zerod itself), the simulator, lone programs by name.
@Test func memoryGroupsByAppTasksAndProgram() {
    let gb: UInt64 = 1 << 30
    let samples = [
        ProcessSample(pid: 1, ppid: 0, path: "/sbin/launchd", memory: 1),
        ProcessSample(pid: 10, ppid: 1, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", memory: gb),
        ProcessSample(
            pid: 11, ppid: 10,
            path:
                "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
            memory: 2 * gb),
        ProcessSample(pid: 20, ppid: 1, path: "/Applications/Zero.app/Contents/MacOS/zerod", memory: gb / 4),
        ProcessSample(pid: 21, ppid: 20, path: "/Users/u/.local/bin/claude", memory: gb),
        ProcessSample(pid: 22, ppid: 21, path: "/Applications/Zero.app/Contents/MacOS/zerod", memory: gb / 4),
        ProcessSample(pid: 23, ppid: 22, path: "/opt/homebrew/bin/node", memory: gb / 2),
        ProcessSample(
            pid: 30, ppid: 1, path: "/Applications/OrbStack.app/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper",
            memory: 17 * gb),
        ProcessSample(
            pid: 40, ppid: 1,
            path:
                "/Library/Developer/CoreSimulator/Volumes/iOS_23A/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.simruntime/Contents/Resources/RuntimeRoot/System/Library/CoreServices/SpringBoard.app/SpringBoard",
            memory: 3 * gb),
        ProcessSample(pid: 50, ppid: 1, path: "/opt/homebrew/bin/node", memory: gb / 4),
        ProcessSample(pid: 51, ppid: 1, path: "/usr/bin/python3", memory: 9 * gb),
    ]
    let groups = MemoryGroup.group(samples)
    #expect(groups.map(\.name) == ["OrbStack", "python3", "Google Chrome", "Simulator", "Zero's tasks", "Zero", "node", "launchd"])
    #expect(groups.first { $0.name == "Google Chrome" }?.memory == 3 * gb)
    #expect(groups.first { $0.tasks }?.memory == gb * 7 / 4)
    #expect(groups.first { $0.tasks }?.processes == 3)
    #expect(groups.first { $0.name == "Zero" }?.memory == gb / 4)
}

/// Short by the kernel's word, or by the compressor or swap even when the kernel calls it normal.
@Test func memoryIsShortByKernelCompressorOrSwap() {
    let gb: UInt64 = 1 << 30
    #expect(!MemoryWatch.isShort(level: 1, compressed: 2 * gb, swapUsed: gb / 2, swapTotal: 2 * gb, ram: 48 * gb))
    #expect(MemoryWatch.isShort(level: 2, compressed: 0, swapUsed: 0, swapTotal: 0, ram: 48 * gb))
    #expect(MemoryWatch.isShort(level: 1, compressed: 23 * gb, swapUsed: 0, swapTotal: 0, ram: 48 * gb))
    #expect(MemoryWatch.isShort(level: 1, compressed: 0, swapUsed: 4 * gb, swapTotal: 5 * gb, ram: 48 * gb))
    // Nearly full but small swap is no lag.
    #expect(!MemoryWatch.isShort(level: 1, compressed: 0, swapUsed: gb / 2, swapTotal: gb / 2, ram: 48 * gb))
}

/// The real machine's processes read, and what a listing costs.
@Test func processesAreReadCheaply() {
    let start = ContinuousClock.now
    let samples = MemoryWatch.processes()
    let groups = MemoryGroup.group(samples)
    let took = ContinuousClock.now - start
    print(
        "memory scan: \(samples.count) processes, \(groups.count) groups, \(took); top: \(groups.prefix(6).map { "\($0.name) \($0.memory >> 20) MB/\($0.processes)" })"
    )
    #expect(samples.contains { $0.pid == getpid() })
    #expect(took < .milliseconds(200))
}

/// What the watch costs while memory is fine: one read of the counters every 30 s.
@Test func countersAreNearlyFree() {
    let start = ContinuousClock.now
    for _ in 0..<1000 { _ = MemoryWatch.counters() }
    let each = (ContinuousClock.now - start) / 1000
    print("memory counters: \(each) a read")
    #expect(each < .milliseconds(1))
}
