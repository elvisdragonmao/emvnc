import Foundation

/// Converts macOS scroll deltas into RFB wheel button clicks. Trackpads report small precise deltas that
/// are accumulated; mouse wheels report line deltas that map to clicks directly.
public struct ScrollAccumulator: Sendable {
    /// Points of precise scrolling that make one wheel click.
    public var pointsPerStep: CGFloat = 12

    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0

    public init() {}

    public mutating func reset() {
        accumulatedX = 0
        accumulatedY = 0
    }

    /// `deltaY > 0` means content should move down, i.e. scroll towards the top (wheel up),
    /// matching `NSEvent.scrollingDeltaY` with the user's natural-scrolling setting already applied.
    public mutating func steps(deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool) -> [(ScrollDirection, Int)] {
        var result: [(ScrollDirection, Int)] = []

        if isPrecise {
            accumulatedX += deltaX
            accumulatedY += deltaY

            let stepsY = Int(accumulatedY / pointsPerStep)
            let stepsX = Int(accumulatedX / pointsPerStep)

            accumulatedY -= CGFloat(stepsY) * pointsPerStep
            accumulatedX -= CGFloat(stepsX) * pointsPerStep

            if stepsY != 0 { result.append((stepsY > 0 ? .up : .down, abs(stepsY))) }
            if stepsX != 0 { result.append((stepsX > 0 ? .left : .right, abs(stepsX))) }
        } else {
            if deltaY != 0 { result.append((deltaY > 0 ? .up : .down, max(1, Int(abs(deltaY).rounded())))) }
            if deltaX != 0 { result.append((deltaX > 0 ? .left : .right, max(1, Int(abs(deltaX).rounded())))) }
        }

        return result
    }
}
