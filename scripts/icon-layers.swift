//
//  icon-layers.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

// Generates the vector layers of Resources/AppIcon.icon (Icon Composer).
//   swift scripts/icon-layers.swift Resources/AppIcon.icon/Assets
//
// Shapes are drawn on Icon Composer's 1024×1024 canvas (SVG space: origin top left, y down).
// Strokes are converted to filled outlines so the glass renderer gets clean, solid shapes.
// Everything is drawn by hand: SF Symbols may not be used in app icons.
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// MARK: Geometry

/// The drive's front: a wide, softly rounded slab.
let body = CGRect(x: 164, y: 444, width: 696, height: 352)
let bodyRadius: CGFloat = 112

/// The lid: a trapezoid behind the body, separated from it by a small gap so the translucent glass
/// layers never overlap.
let lidTop: CGFloat = 228, lidBottom: CGFloat = 420
let lidTopInset: CGFloat = 154, lidBottomInset: CGFloat = 52
let lidTopRadius: CGFloat = 64, lidBottomRadius: CGFloat = 34

/// The heartbeat across the drive's face, and the status light at its end.
let pulseWidth: CGFloat = 70
let baseline = body.midY
let pulsePoints: [CGPoint] = [
    CGPoint(x: 252, y: baseline),
    CGPoint(x: 372, y: baseline),
    CGPoint(x: 434, y: baseline - 104),
    CGPoint(x: 516, y: baseline + 104),
    CGPoint(x: 578, y: baseline),
    CGPoint(x: 668, y: baseline),
]
let light = CGPoint(x: 768, y: baseline)
let lightRadius: CGFloat = 44

func bodyPath() -> CGPath {
    CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)
}

func lidPath() -> CGPath {
    let topLeft = CGPoint(x: body.minX + lidTopInset, y: lidTop)
    let topRight = CGPoint(x: body.maxX - lidTopInset, y: lidTop)
    let bottomRight = CGPoint(x: body.maxX - lidBottomInset, y: lidBottom)
    let bottomLeft = CGPoint(x: body.minX + lidBottomInset, y: lidBottom)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: (topLeft.x + topRight.x) / 2, y: lidTop))
    p.addArc(tangent1End: topRight, tangent2End: bottomRight, radius: lidTopRadius)
    p.addArc(tangent1End: bottomRight, tangent2End: bottomLeft, radius: lidBottomRadius)
    p.addArc(tangent1End: bottomLeft, tangent2End: topLeft, radius: lidBottomRadius)
    p.addArc(tangent1End: topLeft, tangent2End: topRight, radius: lidTopRadius)
    p.closeSubpath()
    return p
}

func pulsePath() -> CGPath {
    let line = CGMutablePath()
    line.addLines(between: pulsePoints)
    let p = CGMutablePath()
    p.addPath(line.copy(strokingWithWidth: pulseWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
        .normalized(using: .winding))
    p.addEllipse(in: CGRect(x: light.x - lightRadius, y: light.y - lightRadius,
                            width: 2 * lightRadius, height: 2 * lightRadius))
    return p
}

// MARK: SVG output

func svgPathData(_ path: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
    path.applyWithBlock { element in
        let p = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: d += "M\(f(p[0].x)) \(f(p[0].y))"
        case .addLineToPoint: d += "L\(f(p[0].x)) \(f(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))"
        case .addCurveToPoint: d += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func writeSVG(_ name: String, _ path: CGPath, color: String) throws {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <path fill="\(color)" d="\(svgPathData(path))"/>
    </svg>
    """
    try svg.write(to: outputDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    print("wrote \(name)")
}

// Default (light) colors; Dark and Tinted are set in icon.json.
try writeSVG("body.svg", bodyPath(), color: "#FFFFFF")
try writeSVG("lid.svg", lidPath(), color: "#CBE8EE")
try writeSVG("pulse.svg", pulsePath(), color: "#00995F")
