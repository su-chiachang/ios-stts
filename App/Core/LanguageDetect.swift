import Foundation

enum LanguageDetect {
    /// Qwen's Chinese voice is selected once Han characters make up more than
    /// 30% of the non-whitespace content; otherwise use English.
    static func spokenLanguage(for text: String) -> SpokenLanguage {
        let content = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !content.isEmpty else { return .en }
        let hanCount = content.filter(isHan).count
        return Double(hanCount) / Double(content.count) > 0.3 ? .zh : .en
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2EBEF, 0x30000...0x323AF:
            true
        default:
            false
        }
    }
}
