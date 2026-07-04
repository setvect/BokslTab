import Foundation

public enum StableWindowTitleKey {
    public static func normalized(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = [" – ", " — ", " - "]
        for separator in separators {
            if let range = trimmed.range(of: separator) {
                return String(trimmed[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
        }
        return trimmed.lowercased()
    }
}
