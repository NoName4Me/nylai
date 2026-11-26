import AppKit
import Foundation

enum LauncherCalculation {
    // Arithmetic grammar only; never evaluate shell, JavaScript, or Objective-C expressions.
    private struct Parser {
        var input: [Character]
        var index = 0
        var current: Character? { index < input.count ? input[index] : nil }
        mutating func skip() { while current?.isWhitespace == true { index += 1 } }
        mutating func take(_ character: Character) -> Bool {
            skip()
            guard current == character else { return false }
            index += 1
            return true
        }
        mutating func expression() -> Double? {
            guard var result = term() else { return nil }
            while true {
                if take("+") { guard let rhs = term() else { return nil }; result += rhs }
                else if take("-") { guard let rhs = term() else { return nil }; result -= rhs }
                else { return result }
            }
        }
        mutating func term() -> Double? {
            guard var result = factor() else { return nil }
            while true {
                if take("*") { guard let rhs = factor() else { return nil }; result *= rhs }
                else if take("/") { guard let rhs = factor(), rhs != 0 else { return nil }; result /= rhs }
                else if take("%") { guard let rhs = factor(), rhs != 0 else { return nil }; result = result.truncatingRemainder(dividingBy: rhs) }
                else { return result }
            }
        }
        mutating func factor() -> Double? {
            skip()
            if take("-") { return factor().map { -$0 } }
            if take("+") { return factor() }
            if take("(") {
                guard let value = expression(), take(")") else { return nil }
                return value
            }
            let start = index
            while let c = current, c.isNumber || c == "." { index += 1 }
            guard index > start else { return nil }
            return Double(String(input[start..<index]))
        }
    }

    static func evaluate(_ input: String) -> String? {
        guard input.count <= 200 else { return nil }
        let value = input.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
        guard value.contains(where: { "+-*/%".contains($0) }) else { return nil }
        var parser = Parser(input: Array(value))
        guard let result = parser.expression(), result.isFinite else { return nil }
        parser.skip()
        guard parser.index == parser.input.count else { return nil }
        return String(format: "%.12g", result)
    }

    static func convert(_ input: String) -> String? {
        let tokens = input.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count == 4, ["in", "to"].contains(tokens[2]), let value = Double(tokens[0]), value.isFinite else { return nil }
        let from = tokens[1], to = tokens[3]
        let lengths: [String: Double] = ["mm": 0.001, "cm": 0.01, "m": 1, "km": 1000, "in": 0.0254, "inch": 0.0254, "ft": 0.3048, "mi": 1609.344]
        let weights: [String: Double] = ["g": 0.001, "kg": 1, "lb": 0.45359237, "oz": 0.028349523125]
        let result: Double
        if let a = lengths[from], let b = lengths[to] { result = value * a / b }
        else if let a = weights[from], let b = weights[to] { result = value * a / b }
        else if from == "c" && to == "f" { result = value * 9 / 5 + 32 }
        else if from == "f" && to == "c" { result = (value - 32) * 5 / 9 }
        else { return nil }
        guard result.isFinite else { return nil }
        return String(format: "%.10g", result) + " " + to
    }

    static func color(_ input: String) -> String? {
        guard input.hasPrefix("#"), input.count == 7, let value = Int(input.dropFirst(), radix: 16) else { return nil }
        return "RGB(\((value >> 16) & 255), \((value >> 8) & 255), \(value & 255))"
    }
}

enum LauncherProcess {
    static func output(_ executable: String, arguments: [String], limit: Int = 1_000_000) async -> String? {
        let task = Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let reader = pipe.fileHandleForReading
            var data = Data()
            while !Task.isCancelled && data.count < limit {
                guard let chunk = try? reader.read(upToCount: min(32_768, limit - data.count)), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            if process.isRunning && (Task.isCancelled || data.count >= limit) { process.terminate() }
            try? reader.close()
            process.waitUntilExit()
            guard !Task.isCancelled, process.terminationStatus == 0 || data.count >= limit else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

enum LauncherFileSearch {
    static func search(_ query: String, roots: [String]) async -> [URL] {
        guard !query.isEmpty else { return [] }
        async let spotlight = LauncherProcess.output("/usr/bin/mdfind", arguments: ["-0", "-interpret", query], limit: 350_000)
        let custom = Task.detached(priority: .utility) { () -> [URL] in
            let normalized = LauncherRank.folded(query)
            let tokens = normalized.split(whereSeparator: \.isWhitespace)
            var result: [URL] = []
            var visited = 0
            for root in roots.prefix(12) {
                guard let iterator = FileManager.default.enumerator(at: URL(fileURLWithPath: (root as NSString).expandingTildeInPath),
                    includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in iterator {
                    if Task.isCancelled || visited >= 30_000 || result.count >= 150 { return result }
                    visited += 1
                    if ["node_modules", "vendor", "DerivedData", "build", "dist", ".git"].contains(url.lastPathComponent) {
                        iterator.skipDescendants(); continue
                    }
                    let path = LauncherRank.folded(url.path)
                    if tokens.allSatisfy({ path.contains($0) }) { result.append(url); continue }
                    let ext = url.pathExtension.lowercased()
                    if ["md", "txt", "swift", "ts", "tsx", "js", "json", "py", "go", "rs", "yaml", "yml", "html", "css", "sql"].contains(ext),
                       let handle = try? FileHandle(forReadingFrom: url) {
                        let data = try? handle.read(upToCount: 64 * 1024)
                        try? handle.close()
                        if let data, let text = String(data: data, encoding: .utf8), tokens.allSatisfy({ LauncherRank.folded(text).contains($0) }) {
                            result.append(url)
                        }
                    }
                }
            }
            return result
        }
        let found = await spotlight
        let independent = await withTaskCancellationHandler { await custom.value } onCancel: { custom.cancel() }
        guard !Task.isCancelled else { return [] }
        let paths = (found ?? "").split(separator: "\0").prefix(350).map { URL(fileURLWithPath: String($0)) }
        var seen = Set<String>()
        return (Array(paths) + independent).filter { seen.insert($0.standardizedFileURL.path).inserted && FileManager.default.fileExists(atPath: $0.path) }
    }
}
