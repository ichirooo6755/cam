import SwiftUI

struct StyleLibraryView: View {
    @Binding var selectedStyleName: String
    @Binding var intensity: Double

    private let styles: [LUTStyle]

    init(selectedStyleName: Binding<String>, intensity: Binding<Double>) {
        self._selectedStyleName = selectedStyleName
        self._intensity = intensity
        self.styles = LUTEngine.availableStyles()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if styles.isEmpty {
                emptyState
            } else {
                styleScroll
            }
            intensitySlider
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.4))
            Text("スタイルなし")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Text("Mac で生成した .cube ファイルを\nFiles アプリ → PiCameraControl/LUTs/ に配置してください。")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Style Cards

    private var styleScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                StyleCard(name: "なし", isSelected: selectedStyleName.isEmpty, iconName: "nosign") {
                    selectedStyleName = ""
                }
                ForEach(styles) { style in
                    StyleCard(
                        name: style.displayName,
                        isSelected: selectedStyleName == style.id,
                        iconName: "camera.filters"
                    ) {
                        selectedStyleName = style.id
                        preload(style.id)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Intensity

    private var intensitySlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("強度")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(intensity * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(
                        selectedStyleName.isEmpty
                            ? .secondary
                            : MinimalTheme.Accent.primary
                    )
            }
            Slider(value: $intensity, in: 0...1)
                .tint(MinimalTheme.Accent.primary)
                .disabled(selectedStyleName.isEmpty)
                .opacity(selectedStyleName.isEmpty ? 0.35 : 1.0)
        }
    }

    // MARK: - Helpers

    private func preload(_ name: String) {
        Task.detached(priority: .userInitiated) {
            _ = LUTEngine.shared.load(named: name)
        }
    }
}

// MARK: - StyleCard

private struct StyleCard: View {
    let name: String
    let isSelected: Bool
    let iconName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            isSelected
                                ? MinimalTheme.Accent.primary.opacity(0.15)
                                : Color(.systemGray5)
                        )
                    Image(systemName: iconName)
                        .font(.system(size: 22))
                        .foregroundColor(
                            isSelected ? MinimalTheme.Accent.primary : .secondary
                        )
                }
                .frame(width: 64, height: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isSelected ? MinimalTheme.Accent.primary : Color.clear,
                            lineWidth: 1.5
                        )
                )

                Text(name)
                    .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(
                        isSelected ? MinimalTheme.Accent.primary : .secondary
                    )
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 64)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }
}
