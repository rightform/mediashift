import ConversionCore
import Foundation

/// Finds the gentlest settings that put an encoded image at or under a size.
enum SizeSearch {
    /// Scale factors tried once quality alone is not enough.
    static let scales: [Double] = [1, 0.85, 0.7, 0.55, 0.4, 0.3, 0.2, 0.12]

    static var tooSmall: ConversionError {
        ConversionError("The target size is too small for this image.")
    }

    /// For formats with a quality dial. At each scale, first checks that the lowest quality fits,
    /// then bisects for the highest quality that still does.
    static func lossy(
        target: Int64,
        floor: Double,
        ceiling: Double,
        encode: (_ quality: Double, _ scale: Double) async throws -> Data
    ) async throws -> Data {
        for scale in scales {
            try Task.checkCancellation()
            let smallest = try await encode(floor, scale)
            guard smallest.count <= target else { continue }

            let best = try await encode(ceiling, scale)
            if best.count <= target { return best }

            var result = smallest
            var low = floor
            var high = ceiling
            for _ in 0 ..< 6 {
                try Task.checkCancellation()
                let middle = (low + high) / 2
                let data = try await encode(middle, scale)
                if data.count <= target {
                    result = data
                    low = middle
                } else {
                    high = middle
                }
            }
            return result
        }
        throw tooSmall
    }

    /// For formats with a list of increasingly harsh settings. Returns the first that fits.
    static func ladder<Step>(
        target: Int64,
        steps: [Step],
        encode: (Step) async throws -> Data
    ) async throws -> Data {
        for step in steps {
            try Task.checkCancellation()
            let data = try await encode(step)
            if data.count <= target { return data }
        }
        throw tooSmall
    }
}
