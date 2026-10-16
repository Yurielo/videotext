import Foundation

enum StableTopicHash {
    static func value(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    static func string(_ text: String) -> String { String(format: "%016llx", value(text)) }
}
