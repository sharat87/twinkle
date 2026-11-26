import Foundation

/// Page zoom: the steps ⌘+ and ⌘- move through. The level for each site is
/// kept in settings.json's `domains`.
public enum Zoom {
    public static let steps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// The next step in or out from `level`, which needn't be a step itself.
    public static func step(from level: Double, in zoomIn: Bool) -> Double {
        let next = zoomIn
            ? steps.first { $0 > level + 0.001 }
            : steps.last { $0 < level - 0.001 }
        return next ?? (zoomIn ? steps.last! : steps.first!)
    }
}
