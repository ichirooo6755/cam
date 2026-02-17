import SwiftUI

/// ジョニー・アイブ デザインシステム
///
/// 原則:
/// 1. ミニマリズム - 不要な要素を徹底的に排除
/// 2. 機能美 - 形は機能に従う
/// 3. 触覚性 - 物理的な操作感
/// 4. 直感性 - 説明不要
/// 5. マテリアルの正直さ - ガラスはガラスらしく

// MARK: - カラーパレット

extension Color {
    /// ジョニー・アイブ風カラーパレット
    struct JonyIve {
        // Primary
        static let graphite = Color(red: 0.15, green: 0.15, blue: 0.17)
        static let silver = Color(red: 0.85, green: 0.85, blue: 0.87)
        static let white = Color.white
        static let black = Color.black

        // Accents
        static let blue = Color(red: 0.0, green: 0.48, blue: 1.0)  // Apple Blue
        static let red = Color(red: 1.0, green: 0.27, blue: 0.23)  // Shutter Red
        static let gold = Color(red: 1.0, green: 0.84, blue: 0.0)  // Gold Accent

        // Glass
        static let glassLight = Color.white.opacity(0.08)
        static let glassDark = Color.black.opacity(0.3)
        static let glassBorder = Color.white.opacity(0.15)
    }
}

// MARK: - タイポグラフィ

extension Font {
    /// ジョニー・アイブ風タイポグラフィシステム
    struct JonyIve {
        // SF Pro Display (Apple標準)
        static func display(_ size: CGFloat, weight: Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .default)
        }

        // SF Mono (技術情報用)
        static func mono(_ size: CGFloat, weight: Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }

        // プリセット
        static let hero = display(48, weight: .black)
        static let title = display(22, weight: .semibold)
        static let body = display(16, weight: .regular)
        static let caption = display(12, weight: .medium)
        static let technical = mono(11, weight: .medium)
    }
}

// MARK: - スペーシング

extension CGFloat {
    /// ジョニー・アイブ風スペーシングシステム（8pxグリッド）
    struct JonyIve {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }
}

// MARK: - ボーダー半径

extension CGFloat {
    /// ジョニー・アイブ風ボーダー半径
    struct JonyIveRadius {
        static let tight: CGFloat = 8   // 小さなボタン
        static let normal: CGFloat = 12  // 通常のカード
        static let comfortable: CGFloat = 16  // パネル
        static let loose: CGFloat = 20   // 大きなカード
        static let circular: CGFloat = 999  // 完全な円
    }
}

// MARK: - ガラスモーフィズム

struct GlassMorphism: ViewModifier {
    var radius: CGFloat = CGFloat.JonyIveRadius.comfortable
    var borderWidth: CGFloat = 0.5
    var shadowRadius: CGFloat = 20
    var shadowY: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.JonyIve.graphite)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius)
                            .stroke(Color.JonyIve.glassBorder, lineWidth: borderWidth)
                    )
                    .shadow(color: .black.opacity(0.3), radius: shadowRadius, y: shadowY)
            )
    }
}

// MARK: - 触覚的ボタン

struct HapticButton: ButtonStyle {
    var activeColor: Color = .JonyIve.blue
    var inactiveColor: Color = .JonyIve.glassLight
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, CGFloat.JonyIve.m)
            .padding(.vertical, CGFloat.JonyIve.s)
            .background(
                RoundedRectangle(cornerRadius: CGFloat.JonyIveRadius.normal)
                    .fill(isActive ? activeColor : inactiveColor)
                    .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
            )
            .foregroundColor(isActive ? .white : .primary)
            .shadow(
                color: isActive ? activeColor.opacity(0.5) : .clear,
                radius: configuration.isPressed ? 5 : 10,
                y: configuration.isPressed ? 2 : 5
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - シャッターボタン

struct ShutterButton: View {
    var action: () -> Void
    var isCapturing: Bool = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // 外側リング（触覚的）
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.6), .white.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 3
                    )
                    .frame(width: 90, height: 90)
                    .shadow(color: .white.opacity(0.3), radius: 10)

                // 内側ボタン
                Circle()
                    .fill(isCapturing ? Color.gray : Color.JonyIve.red)
                    .frame(width: 70, height: 70)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 2)
                    )
                    .shadow(color: Color.JonyIve.red.opacity(0.6), radius: 15)

                // アイコン
                if !isCapturing {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundColor(.white)
                } else {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1.0), trigger: isCapturing)
    }
}

// MARK: - パラメータスライダー

struct ParameterSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0.01
    var unit: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat.JonyIve.xs) {
            HStack {
                Text(title)
                    .font(.JonyIve.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(1.2)

                Spacer()

                Text(String(format: "%.2f", value) + unit)
                    .font(.JonyIve.technical)
                    .foregroundColor(.primary)
                    .monospacedDigit()
            }

            Slider(value: $value, in: range, step: step)
                .accentColor(.JonyIve.blue)
        }
    }
}

// MARK: - Mode Chip

struct ModeChip: View {
    var title: String
    var subtitle: String?
    var isActive: Bool
    var activeColor: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.JonyIve.mono(12, weight: .bold))
                    .foregroundColor(isActive ? .white : .primary)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.JonyIve.mono(9, weight: .medium))
                        .foregroundColor(isActive ? .white.opacity(0.8) : .secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CGFloat.JonyIveRadius.tight)
                    .fill(isActive ? activeColor : Color.JonyIve.glassLight)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CGFloat.JonyIveRadius.tight)
                    .stroke(isActive ? activeColor.opacity(0.5) : .clear, lineWidth: 1)
            )
            .shadow(
                color: isActive ? activeColor.opacity(0.4) : .clear,
                radius: 8,
                y: 4
            )
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: isActive)
    }
}

// MARK: - View Extensions

extension View {
    /// ジョニー・アイブ風ガラスモーフィズムを適用
    func jonyGlass(radius: CGFloat = CGFloat.JonyIveRadius.comfortable) -> some View {
        self.modifier(GlassMorphism(radius: radius))
    }

    /// 触覚的ボタンスタイルを適用
    func hapticButton(activeColor: Color = .JonyIve.blue, isActive: Bool = false) -> some View {
        self.buttonStyle(HapticButton(activeColor: activeColor, isActive: isActive))
    }
}
