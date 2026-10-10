import Foundation

/// Derives the archive folder name for a clip from its filename, falling back
/// to the file's modification date when the name carries no usable timestamp.
///
/// A card can hold thousands of clips, so the formatters are built once per
/// format and reused instead of being allocated per file.
public enum CaptureDate {
    /// DJI writes `DJI_yyyyMMddHHmmss_NNNN_D.MP4`; the second field is the capture time.
    static let timestampLength = 14

    /// `yyyy-MM-dd` archive folder, the single format the importer publishes.
    public static let folderFormat = "yyyy-MM-dd"

    public static func folderName(forFileName name: String, fallback: Date) -> String {
        let formatters = FormatterCache.shared
        if let stamp = djiTimestamp(in: name), let date = formatters.formatter("yyyyMMddHHmmss").date(from: stamp) {
            return formatters.formatter(folderFormat).string(from: date)
        }
        return formatters.formatter(folderFormat).string(from: fallback)
    }

    /// Returns the embedded capture timestamp when `name` is a DJI clip name.
    public static func djiTimestamp(in name: String) -> String? {
        let parts = name.split(separator: "_")
        guard parts.count > 1, parts[0] == "DJI" else { return nil }
        let stamp = parts[1]
        guard stamp.count == timestampLength, stamp.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(stamp)
    }

    /// The lock guards the dictionary; DateFormatter itself is thread-safe on macOS 10.9 and later.
    final class FormatterCache: @unchecked Sendable {
        static let shared = FormatterCache()
        private let lock = NSLock()
        private var formatters: [String: DateFormatter] = [:]

        func formatter(_ format: String) -> DateFormatter {
            lock.lock()
            defer { lock.unlock() }
            if let existing = formatters[format] { return existing }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.isLenient = false
            formatter.dateFormat = format
            formatters[format] = formatter
            return formatter
        }
    }
}
