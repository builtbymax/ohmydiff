import SwiftUI

/// The loading.dev spinner: eight dotted blocks on a 15×15 grid, each fading from full to dim in turn so the
/// brightest block circles the ring clockwise. Sized by `controlSize`, like the `ProgressView` it replaces.
struct Spinner: View {
    var color: Color = Theme.textSecondary
    var duration: Double = 1

    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Top-left corner of each block on the grid, in the order the brightness travels.
    private static let blocks: [CGPoint] = [
        CGPoint(x: 12, y: 6), CGPoint(x: 10, y: 10), CGPoint(x: 6, y: 12), CGPoint(x: 2, y: 10),
        CGPoint(x: 0, y: 6), CGPoint(x: 2, y: 2), CGPoint(x: 6, y: 0), CGPoint(x: 10, y: 2),
    ]
    private static let dots: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 0, y: 2), CGPoint(x: 2, y: 2)]

    private var size: CGFloat {
        switch controlSize {
        case .mini: 13
        case .small: 16
        case .large, .extraLarge: 28
        default: 20
        }
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvasSize in
                let cell = canvasSize.width / 15
                for (step, block) in Self.blocks.enumerated() {
                    var dots = Path()
                    for dot in Self.dots {
                        dots.addRect(CGRect(x: (block.x + dot.x) * cell, y: (block.y + dot.y) * cell, width: cell, height: cell))
                    }
                    context.opacity = reduceMotion ? 0.6 : opacity(step: step, time: time)
                    context.fill(dots, with: .color(color))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Loading")
    }

    /// Each block fades linearly from 1 to 0.2 over `duration`, one eighth of a cycle behind the block before it.
    private func opacity(step: Int, time: TimeInterval) -> Double {
        let elapsed = time / duration + Double(Self.blocks.count - step) / Double(Self.blocks.count)
        return 1 - 0.8 * (elapsed - elapsed.rounded(.down))
    }
}

#Preview {
    HStack(spacing: 16) {
        Spinner().controlSize(.mini)
        Spinner().controlSize(.small)
        Spinner()
        Spinner(color: .orange).controlSize(.large)
    }
    .padding()
}
