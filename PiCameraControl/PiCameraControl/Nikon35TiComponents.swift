import SwiftUI

// MARK: - Nikon 35Ti スタイルのUIコンポーネント

/// カラーテーマ
enum Nikon35TiColors {
    static let background = Color(red: 0.08, green: 0.08, blue: 0.10)
    static let cardBackground = Color(red: 0.15, green: 0.15, blue: 0.17)
    static let accent = Color.red.opacity(0.85)
    static let labelText = Color.gray.opacity(0.9)
    static let valueText = Color.white.opacity(0.95)
    static let divider = Color.gray.opacity(0.2)
}

/// セクションヘッダー
struct Nikon35TiSectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Rectangle()
                .fill(Nikon35TiColors.accent)
                .frame(width: 3, height: 16)

            Text(title)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(Nikon35TiColors.labelText)
                .tracking(1.5)

            Spacer()
        }
        .padding(.vertical, 8)
    }
}

/// 設定カード（統一されたコンテナ）
struct Nikon35TiCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Nikon35TiColors.cardBackground)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        )
    }
}

/// ピッカー（改善版） - protocol Labelable必須
struct Nikon35TiPickerView<T>: View where T: Identifiable, T.ID == String {
    let title: String
    @Binding var selection: T
    let options: [T]
    let labelExtractor: (T) -> String
    let onChange: (T) -> Void

    var body: some View {
        Nikon35TiCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Nikon35TiColors.labelText)
                    .tracking(1.5)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(options) { option in
                            PickerButton(
                                label: labelExtractor(option),
                                isSelected: selection.id == option.id
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selection = option
                                    onChange(option)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// ピッカーボタン
struct PickerButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: isSelected ? .bold : .medium, design: .monospaced))
                .foregroundColor(isSelected ? .white : Nikon35TiColors.labelText)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Nikon35TiColors.accent : Color.gray.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Nikon35TiColors.accent : Color.clear, lineWidth: 2)
                )
        }
    }
}

/// スライダー（改善版）
struct Nikon35TiSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let onChange: () -> Void

    var body: some View {
        Nikon35TiCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Nikon35TiColors.labelText)
                        .tracking(1.5)

                    Spacer()

                    Text(String(format: "%.0f", value.wrappedValue) + unit)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(Nikon35TiColors.accent)
                }

                Slider(value: value, in: range, step: step)
                    .tint(Nikon35TiColors.accent)
                    .onChange(of: value.wrappedValue) { _, _ in
                        onChange()
                    }
            }
        }
    }
}

/// トグル（改善版）
struct Nikon35TiToggle: View {
    let title: String
    let description: String?
    @Binding var isOn: Bool
    let onChange: () -> Void

    init(title: String, description: String? = nil, isOn: Binding<Bool>, onChange: @escaping () -> Void) {
        self.title = title
        self.description = description
        self._isOn = isOn
        self.onChange = onChange
    }

    var body: some View {
        Nikon35TiCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(Nikon35TiColors.valueText)

                    if let description = description {
                        Text(description)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(Nikon35TiColors.labelText)
                    }
                }

                Spacer()

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: Nikon35TiColors.accent))
                    .scaleEffect(0.9)
                    .onChange(of: isOn) { _, _ in
                        onChange()
                    }
            }
        }
    }
}

/// 情報表示行
struct Nikon35TiInfoRow: View {
    let label: String
    let value: String
    let accent: Bool

    init(label: String, value: String, accent: Bool = false) {
        self.label = label
        self.value = value
        self.accent = accent
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(Nikon35TiColors.labelText)

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(accent ? Nikon35TiColors.accent : Nikon35TiColors.valueText)
        }
        .padding(.vertical, 6)
    }
}

/// アクションボタン
struct Nikon35TiButton: View {
    let title: String
    let icon: String?
    let isDestructive: Bool
    let isDisabled: Bool
    let action: () -> Void

    init(title: String, icon: String? = nil, isDestructive: Bool = false, isDisabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isDestructive = isDestructive
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .bold))
                }

                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [
                        (isDestructive ? Color.orange : Nikon35TiColors.accent).opacity(isDisabled ? 0.3 : 0.8),
                        (isDestructive ? Color.orange : Nikon35TiColors.accent).opacity(isDisabled ? 0.2 : 0.6),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(
                color: (isDestructive ? Color.orange : Nikon35TiColors.accent).opacity(isDisabled ? 0 : 0.3),
                radius: 8,
                y: 4
            )
        }
        .disabled(isDisabled)
    }
}

/// グリッドトグル（2列レイアウト用）
struct Nikon35TiGridToggle: View {
    let title: String
    @Binding var isOn: Bool
    let onChange: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Nikon35TiColors.labelText)
                .tracking(1)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Nikon35TiColors.accent))
                .scaleEffect(0.85)
                .onChange(of: isOn) { _, _ in
                    onChange()
                }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Nikon35TiColors.cardBackground)
                .shadow(color: .black.opacity(0.2), radius: 5, y: 3)
        )
    }
}
