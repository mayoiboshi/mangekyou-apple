import Foundation

/// Candidate for the original untextured four-vertex hit branch. Inputs must
/// already be transformed into the coordinate space used by the hit manager.
public enum BarHitGeometry {
    public static func contains(x: Float, y: Float, vertexX: [Float], vertexY: [Float]) -> Bool? {
        guard vertexX.count == 4, vertexY.count == 4, x.isFinite, y.isFinite,
              vertexX.allSatisfy(\.isFinite), vertexY.allSatisfy(\.isFinite),
              let minX = vertexX.min(), let maxX = vertexX.max(),
              let minY = vertexY.min(), let maxY = vertexY.max() else { return nil }
        // 0x50c711–0x50c78b rejects points on either extreme as well as outside.
        guard x > minX, x < maxX, y > minY, y < maxY else { return false }
        for (start, end) in [(0, 3), (3, 2), (2, 1), (1, 0)] {
            // Each subtraction is stored as binary32 before the products are
            // evaluated on x87; binary64 exactly holds these binary32 products.
            let dy = vertexY[start] - vertexY[end]
            let dx = vertexX[end] - vertexX[start]
            let px = x - vertexX[start]
            let py = y - vertexY[start]
            guard dy.isFinite, dx.isFinite, px.isFinite, py.isFinite else { return nil }
            if Double(dy) * Double(px) + Double(dx) * Double(py) > 0 { return false }
        }
        return true
    }
}
