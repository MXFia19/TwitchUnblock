import Foundation
import Combine

final class AppLogger: ObservableObject {
    static let shared = AppLogger()
    private init() {}

    @Published private(set) var logs: [LogEntry] = []
    private var counter = 0
    private let maxLogs = 300

    private func add(_ level: LogLevel, _ category: String, _ message: String, _ detail: String? = nil) {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: now) + String(format: ".%03d", Calendar.current.component(.nanosecond, from: now) / 1_000_000)
        let entry = LogEntry(id: counter, timestamp: timestamp, level: level, category: category, message: message, detail: detail)
        counter += 1
        DispatchQueue.main.async {
            self.logs.insert(entry, at: 0)
            if self.logs.count > self.maxLogs { self.logs = Array(self.logs.prefix(self.maxLogs)) }
        }
        let icons = ["info": "ℹ️", "success": "✅", "warn": "⚠️", "error": "❌", "debug": "🔍"]
        print("\(icons[level.rawValue] ?? "") [\(category)] \(message)\(detail.map { " → \($0)" } ?? "")")
    }

    func info   (_ c: String, _ m: String, _ d: String? = nil) { add(.info,    c, m, d) }
    func success(_ c: String, _ m: String, _ d: String? = nil) { add(.success, c, m, d) }
    func warn   (_ c: String, _ m: String, _ d: String? = nil) { add(.warn,    c, m, d) }
    func error  (_ c: String, _ m: String, _ d: String? = nil) { add(.error,   c, m, d) }
    func debug  (_ c: String, _ m: String, _ d: String? = nil) { add(.debug,   c, m, d) }

    func clear() { DispatchQueue.main.async { self.logs = [] } }
}

let logger = AppLogger.shared
