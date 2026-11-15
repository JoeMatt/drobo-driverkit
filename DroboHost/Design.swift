import SwiftUI

/// The dashboard's visual system: one dark, glassy look built from a handful of primitives.
/// Everything here is presentation only; no view in this file reads or changes Drobo state.
enum Theme {
    static let ink = Color(red: 0.02, green: 0.02, blue: 0.026)
    static let emerald = Color(red: 0.27, green: 0.90, blue: 0.63)
    static let amber = Color(red: 1.00, green: 0.72, blue: 0.30)
    static let coral = Color(red: 1.00, green: 0.42, blue: 0.40)
    static let ice = Color(red: 0.52, green: 0.74, blue: 1.00)

    static let primary = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.56)
    static let tertiary = Color.white.opacity(0.34)
    static let hairline = Color.white.opacity(0.08)

    /// Heavy, slightly overdamped spring used for every state change.
    static let spring = Animation.spring(response: 0.55, dampingFraction: 0.82)

    /// Wide grotesque for names and figures.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Near-black window background with two soft colour fields, drawn once and never animated.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.ink
            Circle()
                .fill(Theme.emerald.opacity(0.16))
                .frame(width: 560, height: 560)
                .blur(radius: 150)
                .offset(x: -330, y: -300)
            Circle()
                .fill(Theme.ice.opacity(0.13))
                .frame(width: 620, height: 620)
                .blur(radius: 170)
                .offset(x: 380, y: 330)
            LinearGradient(colors: [Color.white.opacity(0.035), .clear], startPoint: .top, endPoint: .center)
        }
        .drawingGroup()
    }
}

/// Small uppercase tag that sits above a title.
struct Eyebrow: View {
    let text: String
    var tint: Color = Theme.secondary

    var body: some View {
        Text(text.uppercased())
            .font(Theme.text(9.5, .medium))
            .tracking(1.9)
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Theme.hairline))
    }
}

/// The dashboard's container: a glass plate (core) seated in a thin tray (shell), with
/// concentric corners. Used for every card.
struct Bezel<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    private let shellRadius: CGFloat = 24
    private let inset: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Eyebrow(text: title)
                Spacer(minLength: 0)
                accessory
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: shellRadius - inset, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: shellRadius - inset, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.17), Color.white.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
        )
        .padding(inset)
        .background(
            RoundedRectangle(cornerRadius: shellRadius, style: .continuous).fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: shellRadius, style: .continuous).strokeBorder(Color.white.opacity(0.06))
        )
    }
}

extension Bezel where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// Pill button. With an `icon`, the symbol sits in its own circle flush with the trailing
/// edge and shifts slightly on hover; the whole pill compresses when pressed.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, quiet, danger }
    var kind: Kind = .quiet
    var icon: String?
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, kind: kind, icon: icon, compact: compact)
    }

    private struct Pill: View {
        let configuration: Configuration
        let kind: Kind
        let icon: String?
        let compact: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let foreground: Color = kind == .primary ? .black : (kind == .danger ? Theme.coral : Theme.primary)
            let fill: Color = kind == .primary ? .white
                : kind == .danger ? Theme.coral.opacity(hovering ? 0.20 : 0.12)
                : Color.white.opacity(hovering ? 0.11 : 0.06)
            let edge: Color = kind == .primary ? .clear
                : kind == .danger ? Theme.coral.opacity(0.28) : Color.white.opacity(0.10)
            let well: Color = kind == .primary ? Color.black.opacity(0.09)
                : kind == .danger ? Theme.coral.opacity(0.18) : Color.white.opacity(0.10)
            let circle: CGFloat = compact ? 18 : 22

            HStack(spacing: compact ? 6 : 9) {
                configuration.label
                    .font(Theme.text(compact ? 11 : 12, .medium))
                    .lineLimit(1)
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: compact ? 9 : 10, weight: .regular))
                        .frame(width: circle, height: circle)
                        .background(Circle().fill(well))
                        .offset(x: hovering ? 1.5 : 0, y: hovering ? -1 : 0)
                        .scaleEffect(hovering ? 1.06 : 1)
                }
            }
            .foregroundStyle(foreground)
            .padding(.leading, compact ? 11 : 14)
            .padding(.trailing, icon == nil ? (compact ? 11 : 14) : (compact ? 4 : 5))
            .padding(.vertical, icon == nil ? (compact ? 5 : 8) : (compact ? 4 : 5))
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(edge))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.36)
            .animation(Theme.spring, value: hovering)
            .animation(Theme.spring, value: configuration.isPressed)
            .onHover { hovering = $0 && enabled }
        }
    }
}

/// A bay or status light. Only pulses when `pulsing`, so a healthy, idle dashboard draws nothing
/// continuously.
struct LED: View {
    let color: Color
    var lit = true
    var pulsing = false
    var size: CGFloat = 8
    @State private var beat = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: size, height: size)
                    .scaleEffect(beat ? 2.6 : 1)
                    .opacity(beat ? 0 : 0.9)
                    .onAppear {
                        withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 1.8).repeatForever(autoreverses: false)) { beat = true }
                    }
            }
            Circle()
                .fill(lit ? color : Color.white.opacity(0.12))
                .frame(width: size, height: size)
                .shadow(color: lit ? color.opacity(0.75) : .clear, radius: 4)
        }
        .frame(width: size * 2.6, height: size * 2.6)
    }
}

/// Capacity meter: a track with a glowing fill and quarter ticks.
struct CapacityBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.45), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geo.size.height, geo.size.width * min(max(fraction, 0), 1)))
                    .shadow(color: tint.opacity(0.45), radius: 9)
                HStack(spacing: 0) {
                    ForEach(1..<4, id: \.self) { _ in
                        Spacer()
                        Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1)
                    }
                    Spacer()
                }
            }
            .animation(Theme.spring, value: fraction)
        }
        .frame(height: 10)
    }
}

/// Entry animation: each block settles up into place, staggered by `index`.
private struct Rise: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 20)
            .blur(radius: shown ? 0 : 7)
            .onAppear {
                withAnimation(.spring(response: 0.9, dampingFraction: 0.86).delay(Double(index) * 0.07)) {
                    shown = true
                }
            }
    }
}

extension View {
    func rise(_ index: Int) -> some View { modifier(Rise(index: index)) }
}
