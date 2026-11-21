import Foundation

public enum Format {
    public static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func bytes(_ value: Double) -> String {
        bytes(UInt64(min(max(0, value), Double(Int64.max - 1023))))
    }

    public static func rate(_ value: Double) -> String { bytes(value) + "/s" }
    public static func percent(_ value: Double) -> String { decimal(value) + "%" }

    public static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    static func latency(_ seconds: Double) -> String { decimal(seconds * 1000) + " ms" }
}
