import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Before/After比較 + インライン評価パネル
struct SmartEditFeedbackView: View {
    let originalImage: UIImage
    let editedImage: UIImage
    let appliedCorrections: Set<SmartAutoEditEngine.CorrectionType>
    let onRate: (Int) -> Void
    let onCancel: () -> Void

    @State private var selectedRating: Int = 3
    @State private var compareMode: CompareMode = .slider
    @State private var sliderPosition: CGFloat = 0.5

    enum CompareMode: String, CaseIterable {
        case sideBySide = "並列"
        case slider = "スライダー"
        case tap = "タップ"
    }

    @State private var showingOriginal = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()

            VStack(spacing: 16) {
                // Header
                HStack {
                    Text("スマート編集の評価")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal)

                // Applied corrections badges
                correctionBadges
                    .padding(.horizontal)

                // Before/After comparison
                comparisonView
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                // Compare mode selector
                Picker("比較モード", selection: $compareMode) {
                    ForEach(CompareMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Star rating
                starRatingView
                    .padding(.horizontal)

                // Action buttons
                HStack(spacing: 16) {
                    Button {
                        onCancel()
                    } label: {
                        Text("キャンセル")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemBackground))
                            .foregroundColor(.primary)
                            .cornerRadius(10)
                    }

                    Button {
                        onRate(selectedRating)
                    } label: {
                        Text("保存 (\(selectedRating)星)")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 20)
        }
    }

    // MARK: - Correction Badges

    private var correctionBadges: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(appliedCorrections).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { correction in
                    HStack(spacing: 4) {
                        Image(systemName: iconForCorrection(correction))
                            .font(.caption2)
                        Text(labelForCorrection(correction))
                            .font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(colorForCorrection(correction).opacity(0.2))
                    .foregroundColor(colorForCorrection(correction))
                    .cornerRadius(12)
                }
            }
        }
    }

    private func iconForCorrection(_ type: SmartAutoEditEngine.CorrectionType) -> String {
        switch type {
        case .autoEdit: return "wand.and.stars"
        case .whiteBalance: return "circle.lefthalf.filled"
        case .irCorrection: return "camera.filters"
        case .reference: return "photo"
        case .learning: return "brain"
        }
    }

    private func labelForCorrection(_ type: SmartAutoEditEngine.CorrectionType) -> String {
        switch type {
        case .autoEdit: return "AI編集"
        case .whiteBalance: return "WB補正"
        case .irCorrection: return "IR補正"
        case .reference: return "参考写真"
        case .learning: return "学習"
        }
    }

    private func colorForCorrection(_ type: SmartAutoEditEngine.CorrectionType) -> Color {
        switch type {
        case .autoEdit: return .purple
        case .whiteBalance: return .blue
        case .irCorrection: return .red
        case .reference: return .orange
        case .learning: return .green
        }
    }

    // MARK: - Comparison View

    @ViewBuilder
    private var comparisonView: some View {
        switch compareMode {
        case .sideBySide:
            sideBySideView
        case .slider:
            sliderCompareView
        case .tap:
            tapCompareView
        }
    }

    private var sideBySideView: some View {
        HStack(spacing: 2) {
            VStack(spacing: 4) {
                Text("BEFORE")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.gray)
                Image(uiImage: originalImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            VStack(spacing: 4) {
                Text("AFTER")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.purple)
                Image(uiImage: editedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
    }

    private var sliderCompareView: some View {
        GeometryReader { geo in
            ZStack {
                Image(uiImage: originalImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)

                Image(uiImage: editedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .mask(
                        HStack {
                            Rectangle()
                                .frame(width: geo.size.width * sliderPosition)
                            Spacer(minLength: 0)
                        }
                    )

                // Divider line
                HStack {
                    Spacer()
                        .frame(width: geo.size.width * sliderPosition - 1)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2)
                        .shadow(radius: 2)
                    Spacer()
                }

                // Labels
                VStack {
                    HStack {
                        Text("BEFORE")
                            .font(.caption2.weight(.bold))
                            .padding(4)
                            .background(Color.black.opacity(0.6))
                            .foregroundColor(.white)
                            .cornerRadius(4)
                        Spacer()
                        Text("AFTER")
                            .font(.caption2.weight(.bold))
                            .padding(4)
                            .background(Color.purple.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                    .padding(8)
                    Spacer()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        sliderPosition = max(0, min(1, value.location.x / geo.size.width))
                    }
            )
        }
    }

    private var tapCompareView: some View {
        ZStack {
            Image(uiImage: showingOriginal ? originalImage : editedImage)
                .resizable()
                .aspectRatio(contentMode: .fit)

            VStack {
                HStack {
                    Text(showingOriginal ? "BEFORE" : "AFTER")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(showingOriginal ? Color.black.opacity(0.7) : Color.purple.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    Spacer()
                }
                .padding(8)
                Spacer()

                Text("タップで切替")
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .padding(.bottom, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                showingOriginal.toggle()
            }
        }
    }

    // MARK: - Star Rating

    private var starRatingView: some View {
        VStack(spacing: 8) {
            Text("編集の品質を評価")
                .font(.subheadline)
                .foregroundColor(.gray)

            HStack(spacing: 12) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedRating = star
                        }
                    } label: {
                        Image(systemName: star <= selectedRating ? "star.fill" : "star")
                            .font(.title2)
                            .foregroundColor(star <= selectedRating ? .yellow : .gray)
                    }
                }
            }
        }
    }
}
