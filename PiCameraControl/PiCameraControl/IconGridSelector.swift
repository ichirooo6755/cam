import SwiftUI

/// 編集カテゴリ
enum EditorCategory: String, CaseIterable, Identifiable {
    case light = "💡"
    case color = "🎨"
    case effects = "✨"
    case hsl = "🌈"
    case splitToning = "🎭"
    case toneCurve = "📊"
    case crop = "✂️"
    case radial = "⭕"
    case presets = "⭐"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .light: return "sun.max.fill"
        case .color: return "paintpalette.fill"
        case .effects: return "sparkles"
        case .hsl: return "slider.horizontal.below.rectangle"
        case .splitToning: return "square.split.2x1.fill"
        case .toneCurve: return "chart.line.uptrend.xyaxis"
        case .crop: return "crop"
        case .radial: return "circle.lefthalf.filled"
        case .presets: return "star.fill"
        }
    }

    var label: String {
        switch self {
        case .light: return "ライト"
        case .color: return "カラー"
        case .effects: return "エフェクト"
        case .hsl: return "HSL"
        case .splitToning: return "スプリット"
        case .toneCurve: return "カーブ"
        case .crop: return "切り抜き"
        case .radial: return "ラジアル"
        case .presets: return "プリセット"
        }
    }

    var shortLabel: String {
        switch self {
        case .light: return "L"
        case .color: return "C"
        case .effects: return "E"
        case .hsl: return "H"
        case .splitToning: return "S"
        case .toneCurve: return "T"
        case .crop: return "CR"
        case .radial: return "R"
        case .presets: return "P"
        }
    }
}

/// アイコングリッドセレクター（3x3）
struct IconGridSelector: View {
    @Binding var selectedCategory: EditorCategory
    @Environment(\.colorScheme) var colorScheme

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(EditorCategory.allCases) { category in
                CategoryIcon(
                    category: category,
                    isSelected: selectedCategory == category
                )
                .onTapGesture {
                    withAnimation(MinimalAnimation.springEase) {
                        selectedCategory = category
                    }
                }
            }
        }
        .padding(MinimalSpacing.md)
        .minimalCard()
    }
}

/// カテゴリアイコン
struct CategoryIcon: View {
    let category: EditorCategory
    let isSelected: Bool
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            // アイコン
            Image(systemName: category.icon)
                .font(.system(size: 24, weight: isSelected ? .semibold : .regular))
                .foregroundColor(
                    isSelected
                        ? MinimalTheme.Accent.primary
                        : MinimalTheme.Text.secondary
                )
                .frame(width: 48, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            isSelected
                                ? MinimalTheme.Accent.primary.opacity(0.1)
                                : Color.clear
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isSelected
                                ? MinimalTheme.Accent.primary
                                : Color.clear,
                            lineWidth: 0.5
                        )
                )

            // ラベル
            Text(category.label)
                .font(MinimalTypography.labelSmall)
                .foregroundColor(
                    isSelected
                        ? MinimalTheme.Text.primary
                        : MinimalTheme.Text.secondary
                )
        }
        .frame(maxWidth: .infinity)
        .scaleEffect(isSelected ? 1.0 : 0.95)
        .animation(MinimalAnimation.springEase, value: isSelected)
    }
}

// MARK: - Preview

struct IconGridSelector_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            IconGridSelector(selectedCategory: .constant(.light))
                .padding()
        }
        .background(MinimalTheme.Background.primary)
    }
}
