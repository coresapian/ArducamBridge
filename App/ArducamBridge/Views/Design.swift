import SwiftUI

enum AppTheme {
    static let backgroundTop = Color(red: 0.07, green: 0.10, blue: 0.13)
    static let backgroundBottom = Color(red: 0.12, green: 0.08, blue: 0.11)
    static let panel = Color(red: 0.11, green: 0.14, blue: 0.18)
    static let panelSecondary = Color(red: 0.15, green: 0.11, blue: 0.10)
    static let highlight = Color(red: 0.99, green: 0.76, blue: 0.38)
    static let accent = Color(red: 0.26, green: 0.75, blue: 0.64)
    static let alert = Color(red: 0.95, green: 0.42, blue: 0.39)
    static let fallback = Color(red: 0.97, green: 0.66, blue: 0.28)
    static let text = Color(red: 0.96, green: 0.95, blue: 0.92)
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppTheme.backgroundTop,
                    AppTheme.backgroundBottom,
                    Color(red: 0.08, green: 0.10, blue: 0.16),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(AppTheme.highlight.opacity(0.18))
                .frame(width: 260, height: 260)
                .blur(radius: 26)
                .offset(x: -130, y: -250)

            Circle()
                .fill(AppTheme.accent.opacity(0.17))
                .frame(width: 320, height: 320)
                .blur(radius: 34)
                .offset(x: 160, y: 260)
        }
        .ignoresSafeArea()
    }
}

struct PanelCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                AppTheme.panel.opacity(0.96),
                                AppTheme.panelSecondary.opacity(0.92),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 20, y: 10)
    }
}

extension View {
    func panelCard() -> some View {
        modifier(PanelCardModifier())
    }
}

struct StatusPill: View {
    let title: String
    let tone: StatusTone

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)
                .shadow(color: accent.opacity(0.8), radius: 6)

            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.8)
                .textCase(.uppercase)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.28), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var accent: Color {
        switch tone {
        case .idle:
            return AppTheme.highlight
        case .live, .success:
            return AppTheme.accent
        case .fallback:
            return AppTheme.fallback
        case .error:
            return AppTheme.alert
        }
    }
}

extension PreviewMode {
    var statusTone: StatusTone {
        switch self {
        case .idle:
            return .idle
        case .connecting:
            return .idle
        case .live:
            return .live
        case .fallback:
            return .fallback
        case .error:
            return .error
        }
    }

    var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .connecting:
            return "Connecting"
        case .live:
            return "Live"
        case .fallback:
            return "Fallback"
        case .error:
            return "Issue"
        }
    }
}

extension StatusTone {
    var accentColor: Color {
        switch self {
        case .idle:
            return AppTheme.highlight
        case .live, .success:
            return AppTheme.accent
        case .fallback:
            return AppTheme.fallback
        case .error:
            return AppTheme.alert
        }
    }
}
