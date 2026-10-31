import AppKit
import ConversionKit
import SwiftUI

/// The signature of the app: formats ring the cursor mid-drag. Glass belongs here because
/// the wheel floats above whatever the person is working on, and only for a moment.
struct WheelView: View {
    let model: WheelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            ZStack {
                hub
                ForEach(Array(model.actions.enumerated()), id: \.offset) { index, action in
                    chip(action, index: index)
                }
            }
        }
        .frame(width: model.diameter, height: model.diameter)
        .scaleEffect(model.isVisible || reduceMotion ? 1 : 0.86)
        .opacity(model.isVisible ? 1 : 0)
        .animation(reduceMotion ? .linear(duration: 0.1) : .spring(duration: 0.22, bounce: 0.22), value: model.isVisible)
    }

    private var hub: some View {
        VStack(spacing: 2) {
            if model.highlighted == nil {
                FileIconView(urls: model.urls)
                    .frame(width: 36, height: 36)
            }
            Text(model.hubTitle)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
            // Fixed strength: over an unknown desktop, the vibrant secondary style can fall below 4.5:1.
            Text(model.hubSubtitle)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(12)
        .frame(width: WheelModel.hubRadius * 2, height: WheelModel.hubRadius * 2)
        .glassEffect(.regular, in: Circle())
    }

    private func chip(_ action: ConversionAction, index: Int) -> some View {
        let isHighlighted = model.highlighted == index
        let offset = model.offset(of: index)
        return HStack(spacing: 4) {
            if let symbol = action.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(action.chipLabel)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .frame(width: WheelModel.chipSize.width + (action.symbolName == nil ? 0 : 22), height: WheelModel.chipSize.height)
        // Solid rather than tinted glass, so the target stands out over any wallpaper.
        .background(isHighlighted ? Color.accentColor : .clear, in: Capsule())
        .glassEffect(isHighlighted ? .identity : .regular, in: Capsule())
        .scaleEffect(isHighlighted && !reduceMotion ? 1.1 : 1)
        .offset(model.isVisible || reduceMotion ? offset : .zero)
        .animation(reduceMotion ? nil : .spring(duration: 0.16, bounce: 0.2), value: isHighlighted)
        .animation(reduceMotion ? nil : .spring(duration: 0.26, bounce: 0.18).delay(Double(index) * 0.006), value: model.isVisible)
        .accessibilityLabel(action.title)
    }
}

struct FileIconView: NSViewRepresentable {
    let urls: [URL]

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = NSWorkspace.shared.icon(forFiles: urls.map(\.path))
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}
