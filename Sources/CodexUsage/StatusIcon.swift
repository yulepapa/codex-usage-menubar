import AppKit

enum StatusIcon {
    static func make() -> NSImage {
        // Original Codex "codex-light-16" artwork, ported without changing its paths.
        // The reference SVG and attribution are in Resources/CodexStatusTemplate.svg.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            // Preserve the SVG's top-down 16 × 16 coordinate system at menu bar size.
            let transform = NSAffineTransform()
            transform.translateX(by: 0, yBy: 18)
            transform.scaleX(by: 18.0 / 16.0, yBy: -18.0 / 16.0)
            transform.concat()
            NSColor.black.setFill()

            let path0 = NSBezierPath()
            path0.move(to: NSPoint(x: 10.6667, y: 9.14094))
            path0.curve(to: NSPoint(x: 11.1921, y: 9.66633), controlPoint1: NSPoint(x: 10.9564, y: 9.14107), controlPoint2: NSPoint(x: 11.1919, y: 9.37658))
            path0.curve(to: NSPoint(x: 10.6667, y: 10.1917), controlPoint1: NSPoint(x: 11.1921, y: 9.9562), controlPoint2: NSPoint(x: 10.9565, y: 10.1916))
            path0.line(to: NSPoint(x: 8.66667, y: 10.1917))
            path0.curve(to: NSPoint(x: 8.14128, y: 9.66633), controlPoint1: NSPoint(x: 8.37672, y: 10.1917), controlPoint2: NSPoint(x: 8.14128, y: 9.95628))
            path0.curve(to: NSPoint(x: 8.66667, y: 9.14094), controlPoint1: NSPoint(x: 8.14141, y: 9.37649), controlPoint2: NSPoint(x: 8.37681, y: 9.14094))
            path0.line(to: NSPoint(x: 10.6667, y: 9.14094))
            path0.close()
            path0.fill()

            let path1 = NSBezierPath()
            path1.move(to: NSPoint(x: 5.39617, y: 5.88313))
            path1.curve(to: NSPoint(x: 6.11687, y: 6.06282), controlPoint1: NSPoint(x: 5.64468, y: 5.73412), controlPoint2: NSPoint(x: 5.96764, y: 5.81446))
            path1.line(to: NSPoint(x: 7.01433, y: 7.55793))
            path1.curve(to: NSPoint(x: 7.01433, y: 8.44172), controlPoint1: NSPoint(x: 7.17727, y: 7.82969), controlPoint2: NSPoint(x: 7.17732, y: 8.16999))
            path1.line(to: NSPoint(x: 6.11687, y: 9.93684))
            path1.curve(to: NSPoint(x: 5.39617, y: 10.1165), controlPoint1: NSPoint(x: 5.96773, y: 10.1853), controlPoint2: NSPoint(x: 5.64474, y: 10.2655))
            path1.curve(to: NSPoint(x: 5.21648, y: 9.3968), controlPoint1: NSPoint(x: 5.14794, y: 9.96727), controlPoint2: NSPoint(x: 5.06754, y: 9.64526))
            path1.line(to: NSPoint(x: 6.05437, y: 8.00032))
            path1.line(to: NSPoint(x: 5.21648, y: 6.60383))
            path1.curve(to: NSPoint(x: 5.39617, y: 5.88313), controlPoint1: NSPoint(x: 5.06736, y: 6.3553), controlPoint2: NSPoint(x: 5.14776, y: 6.03238))
            path1.close()
            path1.fill()

            let path2 = NSBezierPath()
            path2.move(to: NSPoint(x: 6.23992, y: 1.43098))
            path2.curve(to: NSPoint(x: 9.38542, y: 2.21516), controlPoint1: NSPoint(x: 7.46406, y: 1.1031), controlPoint2: NSPoint(x: 8.54982, y: 1.45396))
            path2.curve(to: NSPoint(x: 12.8093, y: 3.19172), controlPoint1: NSPoint(x: 10.5383, y: 1.98366), controlPoint2: NSPoint(x: 11.9155, y: 2.29793))
            path2.curve(to: NSPoint(x: 13.7829, y: 6.44953), controlPoint1: NSPoint(x: 13.6945, y: 4.07741), controlPoint2: NSPoint(x: 14.0164, y: 5.30994))
            path2.curve(to: NSPoint(x: 14.569, y: 9.76008), controlPoint1: NSPoint(x: 14.5557, y: 7.31992), controlPoint2: NSPoint(x: 14.8933, y: 8.54971))
            path2.curve(to: NSPoint(x: 12.2331, y: 12.2337), controlPoint1: NSPoint(x: 14.2447, y: 10.9704), controlPoint2: NSPoint(x: 13.3375, y: 11.8664))
            path2.curve(to: NSPoint(x: 9.76042, y: 14.5687), controlPoint1: NSPoint(x: 11.8657, y: 13.3376), controlPoint2: NSPoint(x: 10.9704, y: 14.2443))
            path2.curve(to: NSPoint(x: 6.44988, y: 13.7825), controlPoint1: NSPoint(x: 8.54999, y: 14.893), controlPoint2: NSPoint(x: 7.32025, y: 14.5555))
            path2.curve(to: NSPoint(x: 3.19206, y: 12.8089), controlPoint1: NSPoint(x: 5.3103, y: 14.0161), controlPoint2: NSPoint(x: 4.07777, y: 13.6943))
            path2.curve(to: NSPoint(x: 2.2155, y: 9.54817), controlPoint1: NSPoint(x: 2.30603, y: 11.9228), controlPoint2: NSPoint(x: 1.98129, y: 10.6886))
            path2.curve(to: NSPoint(x: 1.43132, y: 6.23957), controlPoint1: NSPoint(x: 1.44398, y: 8.67777), controlPoint2: NSPoint(x: 1.10733, y: 7.44883))
            path2.curve(to: NSPoint(x: 3.76628, y: 3.76496), controlPoint1: NSPoint(x: 1.7556, y: 5.02965), controlPoint2: NSPoint(x: 2.66205, y: 4.13253))
            path2.curve(to: NSPoint(x: 6.23992, y: 1.43098), controlPoint1: NSPoint(x: 4.13401, y: 2.66129), controlPoint2: NSPoint(x: 5.0304, y: 1.75519))
            path2.close()
            path2.move(to: NSPoint(x: 8.84636, y: 3.15461))
            path2.curve(to: NSPoint(x: 6.51238, y: 2.44563), controlPoint1: NSPoint(x: 8.21242, y: 2.48417), controlPoint2: NSPoint(x: 7.42544, y: 2.20118))
            path2.curve(to: NSPoint(x: 4.69988, y: 4.30989), controlPoint1: NSPoint(x: 5.58126, y: 2.69512), controlPoint2: NSPoint(x: 4.90916, y: 3.43143))
            path2.line(to: NSPoint(x: 4.62566, y: 4.62434))
            path2.line(to: NSPoint(x: 4.3112, y: 4.69953))
            path2.curve(to: NSPoint(x: 2.44597, y: 6.51203), controlPoint1: NSPoint(x: 3.43254, y: 4.90862), controlPoint2: NSPoint(x: 2.69555, y: 5.58058))
            path2.curve(to: NSPoint(x: 3.15495, y: 9.01399), controlPoint1: NSPoint(x: 2.19659, y: 7.44329), controlPoint2: NSPoint(x: 2.49878, y: 8.39365))
            path2.line(to: NSPoint(x: 3.38933, y: 9.23567))
            path2.line(to: NSPoint(x: 3.29753, y: 9.54524))
            path2.curve(to: NSPoint(x: 3.93425, y: 12.0657), controlPoint1: NSPoint(x: 3.03946, y: 10.4106), controlPoint2: NSPoint(x: 3.25264, y: 11.384))
            path2.curve(to: NSPoint(x: 6.45574, y: 12.7025), controlPoint1: NSPoint(x: 4.61596, y: 12.7473), controlPoint2: NSPoint(x: 5.59015, y: 12.9608))
            path2.line(to: NSPoint(x: 6.76531, y: 12.6097))
            path2.line(to: NSPoint(x: 6.98699, y: 12.845))
            path2.curve(to: NSPoint(x: 9.48894, y: 13.555), controlPoint1: NSPoint(x: 7.6075, y: 13.5014), controlPoint2: NSPoint(x: 8.55777, y: 13.8045))
            path2.curve(to: NSPoint(x: 11.2995, y: 11.6888), controlPoint1: NSPoint(x: 10.4198, y: 13.3054), controlPoint2: NSPoint(x: 11.0903, y: 12.5676))
            path2.line(to: NSPoint(x: 11.3747, y: 11.3753))
            path2.line(to: NSPoint(x: 11.6891, y: 11.3001))
            path2.curve(to: NSPoint(x: 13.5553, y: 9.4886), controlPoint1: NSPoint(x: 12.568, y: 11.091), controlPoint2: NSPoint(x: 13.3058, y: 10.4198))
            path2.curve(to: NSPoint(x: 12.8454, y: 6.98664), controlPoint1: NSPoint(x: 13.8048, y: 8.55744), controlPoint2: NSPoint(x: 13.5017, y: 7.60715))
            path2.line(to: NSPoint(x: 12.611, y: 6.76496))
            path2.line(to: NSPoint(x: 12.7028, y: 6.45539))
            path2.curve(to: NSPoint(x: 12.0671, y: 3.93391), controlPoint1: NSPoint(x: 12.961, y: 5.59001), controlPoint2: NSPoint(x: 12.7483, y: 4.61562))
            path2.curve(to: NSPoint(x: 9.37761, y: 3.29719), controlPoint1: NSPoint(x: 11.3946, y: 3.26145), controlPoint2: NSPoint(x: 10.2567, y: 3.03482))
            path2.line(to: NSPoint(x: 9.06804, y: 3.38996))
            path2.line(to: NSPoint(x: 8.84636, y: 3.15461))
            path2.close()
            path2.windingRule = .evenOdd
            path2.fill()

            return true
        }
        // AppKit supplies the color for light, dark, and selected menu bar states.
        image.isTemplate = true
        return image
    }
}
