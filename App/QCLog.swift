import Foundation

/// Minimal append-only log so handoff problems can be diagnosed after the
/// fact. The app is usually behind whatever you're working in, so on-screen
/// messages scroll past unseen — this keeps a record of what actually
/// happened, in order.
///
/// Writes to ~/Library/Logs/Samcast.log
enum QCLog {
    private static let queue = DispatchQueue(label: "com.quackcast.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let url: URL? = {
        guard let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("Samcast.log")
    }()

    static func write(_ message: String) {
        guard let url else { return }
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
