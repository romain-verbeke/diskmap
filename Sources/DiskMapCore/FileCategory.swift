/// Broad file type used to color the treemap.
public enum FileCategory: UInt8, CaseIterable, Sendable {
    case other, video, audio, images, documents, archives, developer, apps, cache, system

    public var label: String {
        switch self {
        case .other: "Other"
        case .video: "Video"
        case .audio: "Audio"
        case .images: "Images"
        case .documents: "Documents"
        case .archives: "Archives"
        case .developer: "Developer"
        case .apps: "Apps"
        case .cache: "Caches"
        case .system: "System"
        }
    }
}

/// Classifies names without allocating a String per file: the lowercased
/// extension is packed into a UInt64 and looked up in a table.
struct CategoryClassifier: Sendable {
    private let table: [UInt64: FileCategory]

    init() {
        var table: [UInt64: FileCategory] = [:]
        func add(_ category: FileCategory, _ extensions: String) {
            for ext in extensions.split(separator: " ") {
                table[Self.key(ext.utf8)] = category
            }
        }
        add(.video, "mp4 mov m4v mkv avi webm mpg mpeg wmv flv prores fcpbundle")
        add(.audio, "mp3 m4a aac wav aif aiff flac ogg opus caf logicx")
        add(.images, "jpg jpeg png gif heic heif tif tiff webp bmp raw cr2 cr3 nef arw dng psd ai svg photoslibrary")
        add(.documents, "pdf doc docx xls xlsx ppt pptx pages numbers key txt rtf md csv epub")
        add(.archives, "zip tar gz tgz bz2 xz 7z rar dmg iso pkg xip")
        add(.developer, "swift m h c cc cpp hpp rs go py rb js jsx ts tsx java kt o a dylib so class jar wasm map lock json yaml yml xml sql sqlite db log")
        add(.apps, "app")
        self.table = table
    }

    private static func key(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var key: UInt64 = 0
        for byte in bytes {
            let lower = (byte >= 65 && byte <= 90) ? byte + 32 : byte
            key = (key << 8) | UInt64(lower)
        }
        return key
    }

    /// Returns the category for a file name, looking at an extension of at most 8 bytes.
    func classify(_ name: UnsafeBufferPointer<UInt8>) -> FileCategory {
        var index = name.count - 1
        let lowest = max(1, name.count - 9)  // a leading dot is a hidden file, not an extension
        while index >= lowest {
            if name[index] == 0x2E {
                let ext = UnsafeBufferPointer(rebasing: name[(index + 1)...])
                return ext.isEmpty ? .other : table[Self.key(ext), default: .other]
            }
            index -= 1
        }
        return .other
    }
}
