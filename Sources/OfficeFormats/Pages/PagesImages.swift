import ConversionCore
import Foundation

/// Finds image files through the data references of `TSD.ImageArchive` objects.
struct PagesImages {
    private let store: IWAObjectStore
    private let source: PartSource
    private let fileNames: [UInt64: String]

    init(store: IWAObjectStore, source: PartSource) {
        self.store = store
        self.source = source
        // `TSP.PackageMetadata`: field 4 repeats { identifier 1, preferred name 3, file name 4 }.
        var names: [UInt64: String] = [:]
        for (_, message) in store.all(ofType: IWAType.packageMetadata) {
            for data in message.parsed()?.messages(4) ?? [] {
                guard let identifier = data.varint(1), let name = data.string(4) ?? data.string(3) else { continue }
                names[identifier] = name
            }
        }
        fileNames = names
    }

    func asset(forDrawable identifier: UInt64) -> ImageAsset? {
        guard let message = store.object(identifier) else { return nil }
        // An image may also refer to a thumbnail and its original. The largest is the best.
        var best: (path: String, data: Data)?
        for reference in message.dataReferences {
            guard let path = path(forData: reference), Self.isImage(path),
                let data = try? source.data(forPart: path)
            else { continue }
            if best == nil || data.count > (best?.data.count ?? 0) { best = (path, data) }
        }
        guard let best else { return nil }
        return ImageAsset(data: best.data, mimeType: ImageSupport.mimeType(forPath: best.path))
    }

    private func path(forData reference: UInt64) -> String? {
        if let name = fileNames[reference], source.contains("Data/\(name)") { return "Data/\(name)" }
        // Pages names a data file `name-<identifier>.ext`.
        let marker = "-\(reference)."
        return source.partNames.first { $0.hasPrefix("Data/") && $0.contains(marker) }
    }

    private static func isImage(_ path: String) -> Bool {
        ImageSupport.mimeType(forPath: path).hasPrefix("image/")
    }
}
