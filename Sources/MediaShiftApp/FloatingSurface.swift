import SwiftUI

#if DEBUG
/// Shows the macOS 15 look on a newer system, for visual checks: `MEDIASHIFT_NO_GLASS=1`.
private let forcesMaterial = ProcessInfo.processInfo.environment["MEDIASHIFT_NO_GLASS"] != nil
#else
private let forcesMaterial = false
#endif

extension View {
    /// The wheel and the result note float above whatever is on screen, and only for a moment.
    /// That is what Liquid Glass is for, where the system has it. On macOS 15 the closest material
    /// takes its place, with an edge and a shadow to lift it off a busy desktop.
    /// `isSolid` is for a surface that already has its own color.
    @ViewBuilder
    func floatingSurface<S: Shape>(in shape: S, isSolid: Bool = false) -> some View {
        if #available(macOS 26, *), !forcesMaterial {
            glassEffect(isSolid ? .identity : .regular, in: shape)
        } else if isSolid {
            shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        }
    }
}

/// Groups floating surfaces, so that Liquid Glass renders them together where it exists.
struct FloatingGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *), !forcesMaterial {
            // No spacing: the chips are meant to stay separate shapes, never to melt together.
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}
