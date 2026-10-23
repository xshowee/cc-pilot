// 横向排列几段文字，一行放不下时把放不下的那段整段折到下一行（ticket 23）。
// 每段按自己的理想宽度排，不在段内截断；比整行还宽的段单独占一行并在段内折行。
// 怎么分行由 App 核心的 ChunkWrap 决定，这里只量尺寸、摆位置。每行内顶端对齐。

import SwiftUI

struct WrappingHStack: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 1

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(maxWidth: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(maxWidth: bounds.width, subviews: subviews)
        for (index, frame) in arrangement.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(frame.size))
        }
    }

    private struct Arrangement {
        var frames: [CGRect]
        var size: CGSize
    }

    private func arrange(maxWidth proposed: CGFloat?, subviews: Subviews) -> Arrangement {
        let maxWidth = proposed.flatMap { $0.isFinite ? $0 : nil }
        let sizes = subviews.map { subview -> CGSize in
            let ideal = subview.sizeThatFits(.unspecified)
            guard let maxWidth, ideal.width > maxWidth else { return ideal }
            return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        }
        let placements = ChunkWrap.place(widths: sizes.map { Double($0.width) },
                                         maxWidth: maxWidth.map(Double.init), spacing: Double(spacing))
        let lineCount = (placements.last?.line ?? -1) + 1
        var lineHeights = [CGFloat](repeating: 0, count: lineCount)
        for (placement, size) in zip(placements, sizes) {
            lineHeights[placement.line] = max(lineHeights[placement.line], size.height)
        }
        var lineTops: [CGFloat] = []
        var y: CGFloat = 0
        for height in lineHeights {
            lineTops.append(y)
            y += height + lineSpacing
        }
        let frames = zip(placements, sizes).map { placement, size in
            CGRect(origin: CGPoint(x: CGFloat(placement.x), y: lineTops[placement.line]), size: size)
        }
        let width = frames.map(\.maxX).max() ?? 0
        let height = lineCount == 0 ? 0 : y - lineSpacing
        return Arrangement(frames: frames, size: CGSize(width: width, height: height))
    }
}
