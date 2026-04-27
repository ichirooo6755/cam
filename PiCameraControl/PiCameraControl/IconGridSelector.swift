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
    case style = "🎞"
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
        case .style: return "camera.filters"
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
        case .style: return "スタイル"
        case .presets: return "プリセット"
        }
    }
}

/// アイコンセレクター（横一列スクロール＋折りたたみ対応）
struct IconGridSelector: View {
    @Binding var selectedCategory: EditorCategory
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー（折りたたみボタン）
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selectedCategory.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(MinimalTheme.Accent.primary)

                    Text(selectedCategory.label)
                        .font(MinimalTypography.labelMedium)
                        .foregroundColor(MinimalTheme.Text.primary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(MinimalTheme.Text.tertiary)
                }
                .padding(.horizontal, MinimalSpacing.md)
                .padding(.vertical, 8)
            }

            // 横スクロールアイコン列
            if isExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
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
                    .padding(.horizontal, MinimalSpacing.md)
                    .padding(.vertical, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(MinimalTheme.Background.surfaceDark)
        )
    }
}

/// カテゴリアイコン（コンパクト版）
struct CategoryIcon: View {
    let category: EditorCategory
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: category.icon)
                .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                .foregroundColor(
                    isSelected
                        ? MinimalTheme.Accent.primary
                        : MinimalTheme.Text.secondary
                )
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            isSelected
                                ? MinimalTheme.Accent.primary.opacity(0.12)
                                : Color.clear
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isSelected ? MinimalTheme.Accent.primary : Color.clear,
                            lineWidth: 0.5
                        )
                )

            Text(category.label)
                .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                .foregroundColor(
                    isSelected
                        ? MinimalTheme.Accent.primary
                        : MinimalTheme.Text.secondary
                )
                .lineLimit(1)
        }
        .frame(width: 54, height: 64)
        .scaleEffect(isSelected ? 1.05 : 1.0)
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
