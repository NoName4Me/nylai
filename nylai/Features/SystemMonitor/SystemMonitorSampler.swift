import Foundation
import Darwin

struct SystemMonitorSnapshot: Sendable {
    struct Network: Sendable {
        let name: String
        let received: UInt64
        let sent: UInt64
        let address: String?
    }

    struct Volume: Identifiable, Sendable {
        let id: String
        let name: String
        let total: Int64
        let available: Int64
    }

    let uptime: TimeInterval
    let cpuTicks: [UInt32]?
    let memoryUsed: UInt64?
    let memoryWired: UInt64?
    let memoryCompressed: UInt64?
    let swapUsed: UInt64?
    let networks: [Network]
    let volumes: [Volume]
}

actor SystemMonitorSampler {
    func sample(includeVolumes: Bool, metrics: Set<SystemMonitorMetric> = Set(SystemMonitorMetric.allCases)) -> SystemMonitorSnapshot {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var cpu = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: cpu) / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                metrics.contains(.cpu) ? host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount) : KERN_FAILURE
            }
        }
        var memory = vm_statistics64_data_t()
        var memoryCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: memory) / MemoryLayout<integer_t>.size)
        let memoryResult = withUnsafeMutablePointer(to: &memory) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(memoryCount)) {
                metrics.contains(.memory) ? host_statistics64(host, HOST_VM_INFO64, $0, &memoryCount) : KERN_FAILURE
            }
        }
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        let wired = UInt64(memory.wire_count) * UInt64(pageSize)
        let compressed = UInt64(memory.compressor_page_count) * UInt64(pageSize)
        let internalPages = UInt64(memory.internal_page_count)
        let purgeablePages = UInt64(memory.purgeable_count)
        let used = (internalPages - min(internalPages, purgeablePages)) * UInt64(pageSize) + wired + compressed
        var swap = xsw_usage()
        var swapSize = MemoryLayout.size(ofValue: swap)
        let swapResult = metrics.contains(.memory) ? sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) : -1
        return SystemMonitorSnapshot(
            uptime: ProcessInfo.processInfo.systemUptime,
            cpuTicks: cpuResult == KERN_SUCCESS
                ? [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3] : nil,
            memoryUsed: memoryResult == KERN_SUCCESS ? used : nil,
            memoryWired: memoryResult == KERN_SUCCESS ? wired : nil,
            memoryCompressed: memoryResult == KERN_SUCCESS ? compressed : nil,
            swapUsed: swapResult == 0 ? swap.xsu_used : nil,
            networks: metrics.contains(.network) ? Self.networks() : [],
            volumes: includeVolumes && metrics.contains(.storage) ? Self.volumes() : []
        )
    }

    private static func networks() -> [SystemMonitorSnapshot.Network] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var counters: [String: (UInt64, UInt64)] = [:]
        var addresses: [String: String] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en"),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = interface.ifa_addr else { continue }
            if Int32(address.pointee.sa_family) == AF_LINK, let data = interface.ifa_data {
                let statistics = data.assumingMemoryBound(to: if_data.self).pointee
                counters[name] = (UInt64(statistics.ifi_ibytes), UInt64(statistics.ifi_obytes))
            }
            let family = Int32(address.pointee.sa_family)
            if family == AF_INET || (family == AF_INET6 && addresses[name] == nil) {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len),
                               &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses[name] = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
        }
        return counters.keys.filter { addresses[$0] != nil }.sorted().map { name in
            let values = counters[name] ?? (0, 0)
            return .init(name: name, received: values.0, sent: values.1, address: addresses[name])
        }
    }

    private static func volumes() -> [SystemMonitorSnapshot.Volume] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsLocalKey,
        ]
        let system = URL(fileURLWithPath: "/System/Volumes/Data")
        let external = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]
        ) ?? []
        return ([system] + external.filter { $0.path.hasPrefix("/Volumes/") }).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsLocal == true,
                  let total = values.volumeTotalCapacity, total > 0,
                  let available = values.volumeAvailableCapacity else { return nil }
            return .init(id: url.path, name: values.volumeName ?? url.lastPathComponent,
                         total: Int64(total), available: Int64(available))
        }
    }
}
