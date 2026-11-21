//
//  Glass.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import SwiftUI

// Liquid Glass on macOS 26+, with a translucent-material fallback on macOS 14/15.
// Every glass use in the app goes through these helpers.

extension EnvironmentValues {
    /// True while views are drawn into the PDF report: glass and materials can't be printed, so the
    /// helpers below switch to flat, light, print-friendly surfaces.
    @Entry var isReportRendering = false
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 22, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    func glassCapsule(tint: Color? = nil) -> some View {
        modifier(GlassCapsuleModifier(tint: tint))
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

private struct GlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    @Environment(\.isReportRendering) private var isReport

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if isReport {
            content
                .background(tint?.opacity(0.07) ?? Color.black.opacity(0.025), in: shape)
                .overlay(shape.strokeBorder((tint ?? .black).opacity(0.18), lineWidth: 0.6))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(Glass.regular.tint(tint?.opacity(0.22)).interactive(interactive), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .background(tint?.opacity(0.10) ?? .clear, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
    }
}

private struct GlassCapsuleModifier: ViewModifier {
    let tint: Color?
    @Environment(\.isReportRendering) private var isReport

    func body(content: Content) -> some View {
        if isReport {
            content
                .background(tint?.opacity(0.12) ?? Color.black.opacity(0.05), in: Capsule())
                .overlay(Capsule().strokeBorder((tint ?? .black).opacity(0.25), lineWidth: 0.6))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(Glass.regular.tint(tint?.opacity(0.35)), in: Capsule())
        } else {
            content
                .background(.thinMaterial, in: Capsule())
                .background(tint?.opacity(0.18) ?? .clear, in: Capsule())
        }
    }
}

extension View {
    /// In full screen the toolbar lives in its own opaque window above the content, which shows as a
    /// dark strip over the gradient. Hide it until the pointer reaches the top of the screen (macOS 15+).
    @ViewBuilder
    func toolbarHidesInFullScreen() -> some View {
        if #available(macOS 15.0, *) {
            self.windowToolbarFullScreenVisibility(.onHover)
        } else {
            self
        }
    }
}

/// Groups neighbouring glass shapes so they blend and morph together (macOS 26).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A titled glass section.
struct GlassSection<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    var tint: Color? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.headline)
                    .foregroundStyle(tint ?? .secondary)
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                accessory
            }
            content
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassSurface(cornerRadius: 24)
    }
}

extension GlassSection where Accessory == EmptyView {
    init(title: LocalizedStringKey, symbol: String, tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// Colourful, softly blurred backdrop that gives the glass something to refract.
struct StatusBackdrop: View {
    let color: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    Circle()
                        .fill(color.opacity(scheme == .dark ? 0.38 : 0.30))
                        .frame(width: size.width * 0.75)
                        .offset(x: -size.width * 0.28, y: -size.height * 0.32)
                    Circle()
                        .fill(Color.blue.opacity(scheme == .dark ? 0.26 : 0.16))
                        .frame(width: size.width * 0.65)
                        .offset(x: size.width * 0.34, y: size.height * 0.10)
                    Circle()
                        .fill(Color.purple.opacity(scheme == .dark ? 0.18 : 0.10))
                        .frame(width: size.width * 0.5)
                        .offset(x: -size.width * 0.05, y: size.height * 0.48)
                }
                .frame(width: size.width, height: size.height)
                .blur(radius: 90)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: color)
    }
}
