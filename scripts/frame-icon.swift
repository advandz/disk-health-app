//
//  frame-icon.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

// Places a full-bleed icon rendering (from Icon Composer's ictool) on the macOS app-icon grid:
// an 824 pt body centred on a 1024 pt canvas, with the soft drop shadow macOS icons carry.
//   swift scripts/frame-icon.swift rendered-1024.png framed-1024.png
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let art = NSImage(contentsOfFile: args[1]) else {
    print("usage: frame-icon.swift input.png output.png"); exit(1)
}

let canvas = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 22
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.set()
art.draw(in: NSRect(x: 100, y: 100, width: 824, height: 824))

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
