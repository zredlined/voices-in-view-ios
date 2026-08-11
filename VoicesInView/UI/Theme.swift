import SwiftUI

enum AppTheme {
    static let background = Color(red: 0.045, green: 0.052, blue: 0.065)
    static let card = Color(red: 0.095, green: 0.105, blue: 0.125)
    static let cardBorder = Color.white.opacity(0.10)
    static let primaryText = Color(red: 0.96, green: 0.97, blue: 0.98)
    static let secondaryText = Color(red: 0.73, green: 0.76, blue: 0.81)
    static let accent = Color(red: 0.66, green: 0.78, blue: 0.98)
    static let orange = Color(red: 1.0, green: 0.63, blue: 0.25)
    static let success = Color(red: 0.35, green: 0.83, blue: 0.55)
    static let warning = Color(red: 1.0, green: 0.78, blue: 0.27)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.38)
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

extension View {
    func appCard() -> some View {
        modifier(CardModifier())
    }
}

struct GhostShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height

        path.move(to: CGPoint(x: width * 0.16, y: height * 0.88))
        path.addLine(to: CGPoint(x: width * 0.16, y: height * 0.42))
        path.addCurve(
            to: CGPoint(x: width * 0.84, y: height * 0.42),
            control1: CGPoint(x: width * 0.16, y: height * 0.10),
            control2: CGPoint(x: width * 0.84, y: height * 0.10)
        )
        path.addLine(to: CGPoint(x: width * 0.84, y: height * 0.88))
        path.addCurve(
            to: CGPoint(x: width * 0.67, y: height * 0.78),
            control1: CGPoint(x: width * 0.80, y: height * 0.98),
            control2: CGPoint(x: width * 0.72, y: height * 0.82)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.50, y: height * 0.88),
            control1: CGPoint(x: width * 0.62, y: height * 0.72),
            control2: CGPoint(x: width * 0.55, y: height * 0.82)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.33, y: height * 0.78),
            control1: CGPoint(x: width * 0.45, y: height * 0.82),
            control2: CGPoint(x: width * 0.38, y: height * 0.72)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.16, y: height * 0.88),
            control1: CGPoint(x: width * 0.28, y: height * 0.82),
            control2: CGPoint(x: width * 0.20, y: height * 0.98)
        )
        path.closeSubpath()

        return path
    }
}

struct GhostIcon: View {
    var size: CGFloat = 22

    var body: some View {
        GhostShape()
            .stroke(lineWidth: max(1.5, size * 0.08))
            .frame(width: size, height: size)
            .overlay(alignment: .top) {
                HStack(spacing: size * 0.18) {
                    Circle().frame(width: size * 0.10, height: size * 0.10)
                    Circle().frame(width: size * 0.10, height: size * 0.10)
                }
                .offset(y: size * 0.38)
            }
            .accessibilityHidden(true)
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.bold))
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(
                AppTheme.accent.opacity(configuration.isPressed ? 0.72 : 1),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
