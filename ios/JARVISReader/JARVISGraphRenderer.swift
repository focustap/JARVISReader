import UIKit

// A local, high-contrast graph for confirming Meta Display can show chart images.
// No network, AI, or backend changes are required for this first experiment.
@MainActor
enum JARVISGraphRenderer {
    static func milkDemandCurve() -> UIImage {
        let size = CGSize(width: 640, height: 400)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext

            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(origin: .zero, size: size))

            func line(_ a: CGPoint, _ b: CGPoint, color: UIColor, width: CGFloat = 3) {
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(width)
                context.move(to: a)
                context.addLine(to: b)
                context.strokePath()
            }

            func label(_ value: String, x: CGFloat, y: CGFloat, color: UIColor = .white, fontSize: CGFloat = 22) {
                (value as NSString).draw(
                    at: CGPoint(x: x, y: y),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                        .foregroundColor: color
                    ]
                )
            }

            func dot(_ center: CGPoint) {
                context.setFillColor(UIColor.systemOrange.cgColor)
                context.fillEllipse(in: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
            }

            let xAxis: CGFloat = 94
            let yAxis: CGFloat = 318
            line(CGPoint(x: xAxis, y: 32), CGPoint(x: xAxis, y: yAxis), color: .white)
            line(CGPoint(x: xAxis, y: yAxis), CGPoint(x: 594, y: yAxis), color: .white)

            let a = CGPoint(x: 238, y: 126)
            let b = CGPoint(x: 422, y: 222)
            context.setLineDash(phase: 0, lengths: [9, 8])
            line(CGPoint(x: xAxis, y: a.y), CGPoint(x: a.x, y: a.y), color: .lightGray, width: 2)
            line(CGPoint(x: a.x, y: a.y), CGPoint(x: a.x, y: yAxis), color: .lightGray, width: 2)
            line(CGPoint(x: xAxis, y: b.y), CGPoint(x: b.x, y: b.y), color: .lightGray, width: 2)
            line(CGPoint(x: b.x, y: b.y), CGPoint(x: b.x, y: yAxis), color: .lightGray, width: 2)
            context.setLineDash(phase: 0, lengths: [])

            // A and B both sit on the same downward-sloping demand curve.
            line(CGPoint(x: 120, y: 64), CGPoint(x: 550, y: 286), color: .systemCyan, width: 5)
            dot(a)
            dot(b)

            label("Price", x: 12, y: 14)
            label("P1", x: 47, y: 111, fontSize: 20)
            label("P2", x: 47, y: 207, fontSize: 20)
            label("Q1", x: 224, y: 324, fontSize: 20)
            label("Q2", x: 407, y: 324, fontSize: 20)
            label("A", x: 254, y: 100, color: .systemOrange)
            label("B", x: 438, y: 194, color: .systemOrange)
            label("D", x: 554, y: 267, color: .systemCyan)
            label("Quantity of milk", x: 220, y: 364, fontSize: 23)
        }
    }
}
