import SwiftUI

// MARK: - Minimal Theme System (Jony Ive-inspired)

/// ミニマルホワイトテーマ - ジョニー・アイブのデザイン哲学に基づく
struct MinimalTheme {
    // MARK: - Colors

    /// 背景色
    struct Background {
        static let primary = Color(hex: "#FAFAFA")      // 極薄グレー
        static let surface = Color(hex: "#FFFFFF")       // 純白
        static let variant = Color(hex: "#F5F5F5")       // カード背景

        // ダークモード
        static let primaryDark = Color(hex: "#000000")
        static let surfaceDark = Color(hex: "#1C1C1E")
        static let variantDark = Color(hex: "#2C2C2E")
    }

    /// テキスト色
    struct Text {
        static let primary = Color(hex: "#1C1C1E")       // ほぼ黒
        static let secondary = Color(hex: "#8E8E93")     // グレー
        static let tertiary = Color(hex: "#C7C7CC")      // 薄グレー

        // ダークモード
        static let primaryDark = Color(hex: "#F5F5F7")
        static let secondaryDark = Color(hex: "#8E8E93")
        static let tertiaryDark = Color(hex: "#48484A")
    }

    /// アクセント色
    struct Accent {
        static let primary = Color(hex: "#007AFF")       // システムブルー
        static let destructive = Color(hex: "#FF3B30")   // システムレッド
        static let success = Color(hex: "#34C759")       // システムグリーン
        static let warning = Color(hex: "#FF9500")       // システムオレンジ
    }

    /// 区切り線
    static let divider = Color(hex: "#E5E5EA")
    static let dividerDark = Color(hex: "#38383A")
}

// MARK: - Typography

/// タイポグラフィシステム
struct MinimalTypography {
    // ディスプレイ
    static let displayLarge = Font.system(size: 34, weight: .bold, design: .default)
    static let displayMedium = Font.system(size: 28, weight: .bold, design: .default)

    // 見出し
    static let headlineLarge = Font.system(size: 22, weight: .semibold, design: .default)
    static let headlineMedium = Font.system(size: 17, weight: .semibold, design: .default)
    static let headlineSmall = Font.system(size: 15, weight: .semibold, design: .default)

    // 本文
    static let bodyLarge = Font.system(size: 17, weight: .regular, design: .default)
    static let bodyMedium = Font.system(size: 15, weight: .regular, design: .default)
    static let bodySmall = Font.system(size: 13, weight: .regular, design: .default)

    // キャプション
    static let caption = Font.system(size: 12, weight: .regular, design: .default)
    static let captionMono = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let captionBold = Font.system(size: 12, weight: .semibold, design: .default)

    // ラベル
    static let labelLarge = Font.system(size: 13, weight: .medium, design: .default)
    static let labelMedium = Font.system(size: 11, weight: .medium, design: .default)
    static let labelSmall = Font.system(size: 9, weight: .medium, design: .default)
}

// MARK: - Spacing

/// スペーシングシステム
struct MinimalSpacing {
    static let xs: CGFloat = 4      // 極小
    static let sm: CGFloat = 8      // 小
    static let md: CGFloat = 16     // 中（標準）
    static let lg: CGFloat = 24     // 大
    static let xl: CGFloat = 32     // 特大
    static let xxl: CGFloat = 48    // 超特大
}

// MARK: - Animations

/// アニメーションシステム
struct MinimalAnimation {
    static let standardEase = Animation.easeInOut(duration: 0.2)
    static let springEase = Animation.spring(response: 0.3, dampingFraction: 0.7)
    static let quickFade = Animation.linear(duration: 0.15)
    static let slowSpring = Animation.spring(response: 0.4, dampingFraction: 0.7)
}

// MARK: - Component Styles

/// ミニマルカード
struct MinimalCard: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(MinimalSpacing.md)
            .background(
                colorScheme == .dark
                    ? MinimalTheme.Background.surfaceDark
                    : MinimalTheme.Background.surface
            )
            .cornerRadius(12)
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.03),
                radius: 8,
                x: 0,
                y: 2
            )
    }
}

/// ミニマルボタンスタイル
struct MinimalButton: ButtonStyle {
    @Environment(\.colorScheme) var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MinimalTypography.bodyMedium)
            .foregroundColor(MinimalTheme.Accent.primary)
            .padding(.horizontal, MinimalSpacing.md)
            .padding(.vertical, MinimalSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                colorScheme == .dark
                                    ? MinimalTheme.dividerDark
                                    : MinimalTheme.divider,
                                lineWidth: 0.5
                            )
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(MinimalAnimation.springEase, value: configuration.isPressed)
    }
}

/// プライマリボタンスタイル
struct MinimalPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MinimalTypography.bodyMedium.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, MinimalSpacing.md)
            .padding(.vertical, MinimalSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(MinimalTheme.Accent.primary)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(MinimalAnimation.springEase, value: configuration.isPressed)
    }
}

/// デストラクティブボタンスタイル
struct MinimalDestructiveButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MinimalTypography.bodyMedium.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, MinimalSpacing.md)
            .padding(.vertical, MinimalSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(MinimalTheme.Accent.destructive)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(MinimalAnimation.springEase, value: configuration.isPressed)
    }
}

// MARK: - View Extensions

extension View {
    /// ミニマルカードスタイルを適用
    func minimalCard() -> some View {
        modifier(MinimalCard())
    }

    /// ミニマルボタンスタイルを適用
    func minimalButtonStyle() -> some View {
        buttonStyle(MinimalButton())
    }

    /// プライマリボタンスタイルを適用
    func minimalPrimaryButtonStyle() -> some View {
        buttonStyle(MinimalPrimaryButton())
    }

    /// デストラクティブボタンスタイルを適用
    func minimalDestructiveButtonStyle() -> some View {
        buttonStyle(MinimalDestructiveButton())
    }
}

// MARK: - Color Extension

extension Color {
    /// Hex文字列からColorを生成
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
