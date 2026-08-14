import Foundation

enum ItemKind: Int {
    case text = 0
    case rich = 1
    case image = 2
    case files = 3

    var label: String {
        switch self {
        case .text: return "Text"
        case .rich: return "Rich text"
        case .image: return "Image"
        case .files: return "Files"
        }
    }
}

/// One pasteboard representation: a UTI and its bytes.
struct Representation {
    let uti: String
    let data: Data
}

/// A row of `items`, without any payload attached. This is what the list shows;
/// the actual bytes are only read when something is pasted or previewed.
struct ClipItem {
    let id: Int64
    let hash: String
    let kind: ItemKind
    let snippet: String
    let sourceBundleID: String?
    let sourceName: String?
    let createdAt: Double
    let updatedAt: Double
    let totalBytes: Int64
    let hasThumb: Bool
    let pixelWidth: Int
    let pixelHeight: Int
}

/// A freshly observed clipboard change, before it is written to the store.
struct CapturedPayload {
    let reps: [Representation]
    let kind: ItemKind
    let snippet: String
    let sourceBundleID: String?
    let sourceName: String?
    let hash: String
    let totalBytes: Int
    let pixelSize: CGSize?
    /// Full-size image bytes kept aside for thumbnailing; not retained after write.
    let imageForThumb: Data?
}
