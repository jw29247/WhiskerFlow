import Foundation
import Darwin

/// Native counters only: no process enumeration, document data or shell commands.
/// Called on the health monitor's utility queue, never on the main actor.
final class ResourceDiagnosticSampler {
    private var previous: (time: Double, cpu: Double, total: UInt64, idle: UInt64)?
    private var previousSwap: (input: UInt64, output: UInt64)?
    func snapshot() -> [String: String] {
        let now = ProcessInfo.processInfo.systemUptime
        var fields: [String: String] = ["event": "resource_snapshot", "cpu_count": String(ProcessInfo.processInfo.activeProcessorCount)]
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { fields["load_1m"] = String(load[0]) }
        var usage = rusage()
        let usageOK = getrusage(RUSAGE_SELF, &usage) == 0
        let cpuSeconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var cpu = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let cpuOK = withUnsafeMutablePointer(to: &cpu) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount) == KERN_SUCCESS }
        }
        let total = UInt64(cpu.cpu_ticks.0) + UInt64(cpu.cpu_ticks.1) + UInt64(cpu.cpu_ticks.2) + UInt64(cpu.cpu_ticks.3)
        let idle = UInt64(cpu.cpu_ticks.2)
        if let old = previous, now > old.time {
            if usageOK, cpuSeconds >= old.cpu { fields["app_cpu_percent"] = String((cpuSeconds - old.cpu) / (now - old.time) * 100) }
            if cpuOK, total > old.total, idle >= old.idle {
                fields["system_cpu_percent"] = String(100 * (1 - Double(idle - old.idle) / Double(total - old.total)))
            }
            fields["sample_interval_ms"] = String((now - old.time) * 1000)
        }
        if usageOK && cpuOK { previous = (now, cpuSeconds, total, idle) }
        var task = mach_task_basic_info_data_t()
        var taskCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let taskOK = withUnsafeMutablePointer(to: &task) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(taskCount)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &taskCount) == KERN_SUCCESS }
        }
        if taskOK { fields["rss_bytes"] = String(task.resident_size) }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { fields["swap_used_bytes"] = String(swap.xsu_used) }
        var vm = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let vmOK = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(host, HOST_VM_INFO64, $0, &vmCount) == KERN_SUCCESS }
        }
        if vmOK {
            if let old = previousSwap, vm.swapins >= old.input, vm.swapouts >= old.output {
                fields["swapins_delta_pages"] = String(vm.swapins - old.input)
                fields["swapouts_delta_pages"] = String(vm.swapouts - old.output)
            }
            previousSwap = (vm.swapins, vm.swapouts)
            fields["swapins_pages"] = String(vm.swapins)
            fields["swapouts_pages"] = String(vm.swapouts)
            fields["compressed_pages"] = String(vm.compressor_page_count)
            fields["page_size_bytes"] = String(vm_kernel_page_size)
        }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: fields["thermal_state"] = "nominal"
        case .fair: fields["thermal_state"] = "fair"
        case .serious: fields["thermal_state"] = "serious"
        case .critical: fields["thermal_state"] = "critical"
        @unknown default: fields["thermal_state"] = "unknown"
        }
        return fields
    }
}
