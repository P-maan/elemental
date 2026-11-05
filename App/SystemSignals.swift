import Foundation
import IOKit.ps
import Darwin

/// Reads battery, CPU load and memory in use into `Signals` every five seconds
/// — and only while a ray is actually showing one of them. Each reading is a
/// couple of syscalls; nothing is kept but the latest value.
final class SystemSignals {
    private var timer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?

    func update(layout: [String]) {
        let wanted = layout.contains { ["battery", "cpu", "memory"].contains($0) }
        if wanted, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.read() }
            timer?.tolerance = 2
            read()
        } else if !wanted, let t = timer {
            t.invalidate(); timer = nil
        }
    }

    private func read() {
        if let b = Self.battery() { Signals.shared.set("sys.battery", value: b) }
        if let c = cpu() { Signals.shared.set("sys.cpu", value: c) }
        if let m = Self.memory() { Signals.shared.set("sys.memory", value: m) }
    }

    /// Charge 0..1; nil on a Mac without a battery.
    static func battery() -> Float? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Float(cur) / Float(max)
        }
        return nil
    }

    /// Busy fraction across all cores since the last reading.
    private func cpu() -> Float? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), sys = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + sys + nice, total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return nil }
        return Float(busy - last.busy) / Float(total - last.total)
    }

    /// RAM in use (active + wired + compressed) over physical memory.
    static func memory() -> Float? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * page
        return Float(Double(used) / Double(ProcessInfo.processInfo.physicalMemory))
    }
}
