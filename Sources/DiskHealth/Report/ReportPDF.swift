//
//  ReportPDF.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import AppKit
import SwiftUI

/// Lays report blocks out on pages and renders them into a vector PDF (selectable text).
///
/// Each block is measured with `ImageRenderer` at the content width, blocks are packed onto pages
/// without splitting them, and every page gets a running header and footer.
@MainActor
enum ReportPDF {
    /// Views are laid out wider than the printable area and scaled down, which gives print-sized
    /// type (≈ 10 pt body) while reusing the app's own components unchanged.
    private static let scale: CGFloat = 0.78
    private static let margin: CGFloat = 36
    private static let chromeHeight: CGFloat = 26
    private static let blockSpacing: CGFloat = 12

    struct Drive {
        let name: String
        let blocks: [ReportBlock]
    }

    private struct Placed {
        let view: AnyView
        let height: CGFloat // layout units (before scaling)
    }

    private struct Page {
        let driveName: String
        var items: [Placed] = []
    }

    static func render(_ drives: [Drive], generated: Date = Date()) -> Data {
        let paper = paperSize()
        let layoutWidth = (paper.width - 2 * margin) / scale
        let bodyHeight = (paper.height - 2 * margin - 2 * chromeHeight) / scale

        // 1. Measure and paginate. Every drive starts on a new page.
        var pages: [Page] = []
        for drive in drives {
            var page = Page(driveName: drive.name)
            var used: CGFloat = 0
            let measured = drive.blocks.map { (block: $0, height: measure($0.view, width: layoutWidth)) }
            for (index, item) in measured.enumerated() where item.height > 0 {
                var needed = item.height + (page.items.isEmpty ? 0 : blockSpacing)
                if item.block.keepWithNext {
                    // A heading (or a chain of them) must fit together with the start of what follows.
                    var next = index + 1
                    while next < measured.count, measured[next].block.keepWithNext {
                        needed += blockSpacing + measured[next].height
                        next += 1
                    }
                    if next < measured.count {
                        needed += blockSpacing + min(measured[next].height, bodyHeight / 3)
                    }
                }
                if !page.items.isEmpty, used + needed > bodyHeight {
                    pages.append(page)
                    page = Page(driveName: drive.name)
                    used = 0
                }
                used += item.height + (page.items.isEmpty ? 0 : blockSpacing)
                page.items.append(Placed(view: item.block.view, height: item.height))
            }
            if !page.items.isEmpty { pages.append(page) }
        }

        // 2. Draw.
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }

        for (pageIndex, page) in pages.enumerated() {
            context.beginPDFPage(nil)

            let chrome = ReportPageChrome(driveName: page.driveName, generated: generated, page: pageIndex + 1,
                                          pageCount: pages.count,
                                          size: CGSize(width: (paper.width - 2 * margin) / scale,
                                                       height: (paper.height - 2 * margin) / scale))
            draw(chrome, width: (paper.width - 2 * margin) / scale, in: context, at: CGPoint(x: margin, y: margin))

            // PDF coordinates start at the bottom left; lay blocks out from the top down.
            var top = paper.height - margin - chromeHeight
            for (i, item) in page.items.enumerated() {
                if i > 0 { top -= blockSpacing * scale }
                let height = item.height * scale
                draw(item.view, width: layoutWidth, in: context, at: CGPoint(x: margin, y: top - height))
                top -= height
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    // MARK: - Helpers

    private static func paperSize() -> CGSize {
        let size = NSPrintInfo.shared.paperSize // the user's default paper (A4 or US Letter)
        return size.width > 100 && size.height > 100 ? size : CGSize(width: 612, height: 792)
    }

    private static func renderer(for view: some View, width: CGFloat) -> ImageRenderer<some View> {
        let content = view
            .frame(width: width, alignment: .leading)
            .environment(\.colorScheme, .light)
            .environment(\.isReportRendering, true)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return renderer
    }

    private static func measure(_ view: AnyView, width: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        renderer(for: view, width: width).render { size, _ in height = size.height }
        return height
    }

    private static func draw(_ view: some View, width: CGFloat, in context: CGContext, at origin: CGPoint) {
        renderer(for: view, width: width).render { _, render in
            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y)
            context.scaleBy(x: scale, y: scale)
            render(context)
            context.restoreGState()
        }
    }
}
