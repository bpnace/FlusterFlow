import AppKit
import SwiftUI

enum CoralEclipseStyle {
    static let canvas = adaptive(
        light: NSColor(calibratedRed: 0.985, green: 0.969, blue: 0.949, alpha: 1),
        dark: NSColor(calibratedRed: 0.105, green: 0.090, blue: 0.080, alpha: 1)
    )
    static let sidebar = adaptive(
        light: NSColor(calibratedRed: 0.966, green: 0.932, blue: 0.908, alpha: 1),
        dark: NSColor(calibratedRed: 0.135, green: 0.112, blue: 0.100, alpha: 1)
    )
    static let raisedSurface = adaptive(
        light: NSColor(calibratedRed: 0.997, green: 0.987, blue: 0.976, alpha: 1),
        dark: NSColor(calibratedRed: 0.165, green: 0.140, blue: 0.126, alpha: 1)
    )
    static let ink = adaptive(
        light: NSColor(calibratedRed: 0.115, green: 0.100, blue: 0.092, alpha: 1),
        dark: NSColor(calibratedRed: 0.965, green: 0.938, blue: 0.914, alpha: 1)
    )
    static let secondaryInk = adaptive(
        light: NSColor(calibratedRed: 0.405, green: 0.365, blue: 0.340, alpha: 1),
        dark: NSColor(calibratedRed: 0.745, green: 0.685, blue: 0.645, alpha: 1)
    )
    static let hairline = adaptive(
        light: NSColor(calibratedRed: 0.385, green: 0.280, blue: 0.235, alpha: 0.16),
        dark: NSColor(calibratedRed: 0.945, green: 0.750, blue: 0.680, alpha: 0.16)
    )

    static let coral = Color(red: 0.769, green: 0.239, blue: 0.204)
    static let coralSoft = Color(red: 0.96, green: 0.66, blue: 0.62)
    static let coralMist = Color(red: 0.98, green: 0.82, blue: 0.79)
    static let charcoal = Color(red: 0.095, green: 0.090, blue: 0.085)

    static let panelRadius: CGFloat = 18

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }
        )
    }
}

struct CoralEclipseBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            let diameter = max(proxy.size.height * 2.15, 220)

            ZStack {
                LinearGradient(
                    colors: [
                        CoralEclipseStyle.raisedSurface,
                        CoralEclipseStyle.coralMist.opacity(0.58)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                CoralEclipseStyle.coralSoft.opacity(0.72),
                                CoralEclipseStyle.coral.opacity(0.92)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: diameter, height: diameter)
                    .position(
                        x: proxy.size.width - diameter * 0.12,
                        y: proxy.size.height * 0.72
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: CoralEclipseStyle.panelRadius))
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct CoralPageHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(CoralEclipseStyle.ink)
                .frame(width: 38, height: 38)
                .background(CoralEclipseStyle.coralMist.opacity(0.78), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(CoralEclipseStyle.ink)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(CoralEclipseStyle.secondaryInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
