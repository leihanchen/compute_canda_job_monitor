import AppKit
import SwiftUI

/// Size limits and defaults for the floating panel.
enum PanelSize {
    static let defaultWidth: Double = 380
    static let defaultContentHeight: Double = 460
    static let widthRange: ClosedRange<Double> = 320...1000
    static let minContentHeight: Double = 180

    static func clampedWidth(_ value: Double) -> Double {
        min(max(value, widthRange.lowerBound), widthRange.upperBound)
    }

    /// Caps height so the panel (header + tabs + footer ≈ 160pt) still fits on screen.
    static func clampedContentHeight(_ value: Double) -> Double {
        let screenHeight = Double(NSScreen.main?.visibleFrame.height ?? 900)
        let maxHeight = max(minContentHeight, screenHeight - 180)
        return min(max(value, minContentHeight), maxHeight)
    }
}

/// Bottom-right drag handle that resizes the panel. Double-click restores the default size.
///
/// Menu bar panels are borderless, so macOS gives them no resizable edges; this grip changes
/// the SwiftUI frame and the window follows. Tracking uses screen coordinates
/// (`NSEvent.mouseLocation`) so the panel moving while it grows doesn't cause jitter.
struct ResizeGrip: View {
    @Binding var width: Double
    @Binding var contentHeight: Double

    @State private var dragStart: (mouse: NSPoint, width: Double, height: Double)?

    var body: some View {
        GripShape()
            .stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .frame(width: 12, height: 12)
            .padding(4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        let mouse = NSEvent.mouseLocation
                        let start = dragStart ?? (
                            mouse,
                            PanelSize.clampedWidth(width),
                            PanelSize.clampedContentHeight(contentHeight)
                        )
                        if dragStart == nil { dragStart = start }
                        // Screen y grows upward, so dragging down (smaller y) makes the panel taller.
                        width = PanelSize.clampedWidth(start.width + Double(mouse.x - start.mouse.x))
                        contentHeight = PanelSize.clampedContentHeight(
                            start.height + Double(start.mouse.y - mouse.y)
                        )
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) {
                width = PanelSize.defaultWidth
                contentHeight = PanelSize.defaultContentHeight
            }
            .help("Drag to resize · double-click to reset")
            .accessibilityLabel("Resize panel")
    }
}

/// Three diagonal strokes, like a classic window resize corner.
private struct GripShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [0.0, 0.35, 0.7] {
            let offset = rect.width * fraction
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY + offset))
            path.addLine(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
        }
        return path
    }
}
