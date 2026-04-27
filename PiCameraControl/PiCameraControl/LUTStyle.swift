import Foundation

struct LUTStyle: Identifiable, Hashable {
    let id: String
    var displayName: String
    var source: Source

    enum Source: Hashable {
        case bundle, documents
    }

    static let none = LUTStyle(id: "", displayName: "なし", source: .bundle)
}
