import Foundation

public enum Timecode {
    /// 초 → "HH:MM:SS.mmm" (1시간 미만이면 "MM:SS.mmm")
    public static func format(_ seconds: Double, millis: Bool = true) -> String {
        let total = max(0, seconds)
        let whole = Int(total)
        let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
        let ms = Int(((total - Double(whole)) * 1000).rounded(.down))
        let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
        return millis ? base + String(format: ".%03d", ms) : base
    }

    /// "1:22:33.4", "22:33", "4953.37" 모두 허용
    public static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }
}
