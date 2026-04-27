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

    // リファレンス写真関連
    var referenceImage: UIImage? = nil
    var similarityScore: Int? = nil

    @State private var selectedRating: Int = 3
    @State private var compareMode: CompareMode = .slider
    @State private var sliderPosition: CGFloat = 0.5

    enum CompareMode: String, CaseIterable {
        case sideBySide = "並列"
        case slider = "スライダー"
        case tap = "タップ"
        case reference = "参考写真"
    }

    @State private var showingOriginal = false

    /// リファレンスが無い場合に表示するモード一覧
    private var availableModes: [CompareMode] {
        if referenceImage != nil {
            return CompareMode.allCases
        } else {
            return [.sideBySide, .slider, .tap]
        }
    }

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

                // 類似度ゲージ
                if let score = similarityScore, referenceImage != nil {
                    similarityGauge(score: score)
                        .padding(.horizontal)
                }

                // Before/After comparison
                comparisonView
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                // Compare mode selector
                Picker("比較モード", selection: $compareMode) {
                    ForEach(availableModes, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Star rating
                starRatingView
                    .padding(.horizontal)

                // 類似度ヒント
                if let score = similarityScore, referenceImage != nil {
                    similarityHint(score: score)
                        .padding(.horizontal)
                }

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

    // MARK: - Similarity Gauge

    private func similarityGauge(score: Int) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text("参考写真との類似度")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.gray)
                Spacer()
                Text("\(score)%")
                    .font(.caption.weight(.bold))
                    .foregroundColor(similarityColor(score: score))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(similarityColor(score: score))
                        .frame(width: geo.size.width * CGFloat(score) / 100.0, height: 8)
                }
            }
            .frame(height: 8)
        }
    }

    private func similarityColor(score: Int) -> Color {
        if score >= 80 { return .green }
        if score >= 60 { return .orange }
        return .red
    }

    private func similarityHint(score: Int) -> some View {
        let message: String
        if score >= 90 {
            message = "参考写真にとても近い仕上がりです"
        } else if score >= 70 {
            message = "参考写真に近い雰囲気になっています"
        } else if score >= 50 {
            message = "参考写真と異なる部分があります。手動で微調整してみてください"
        } else {
            message = "参考写真とかなり異なります。色温度や明るさを確認してください"
        }

        return HStack(spacing: 6) {
            Image(systemName: "lightbulb.fill")
                .font(.caption2)
                .foregroundColor(.yellow)
            Text(message)
                .font(.caption2)
                .foregroundColor(.gray)
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
        case .reference:
            referenceCompareView
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

    private var referenceCompareView: some View {
        HStack(spacing: 2) {
            VStack(spacing: 4) {
                Text("参考写真")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.orange)
                if let ref = referenceImage {
                    Image(uiImage: ref)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.gray.opacity(0.3)
                        .overlay(
                            Text("未設定")
                                .font(.caption)
                                .foregroundColor(.gray)
                        )
                }
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

    // MARK: - Star Rating

    private static let starLabels = ["やり直し", "微妙", "普通", "良い", "完璧"]

    private var starRatingView: some View {
        VStack(spacing: 8) {
            Text("編集の品質を評価")
                .font(.subheadline)
                .foregroundColor(.gray)

            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedRating = star
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: star <= selectedRating ? "star.fill" : "star")
                                .font(.title3)
                                .foregroundColor(star <= selectedRating ? .yellow : .gray)
                            Text(Self.starLabels[star - 1])
                                .font(.system(size: 8))
                                .foregroundColor(star == selectedRating ? .yellow : .gray)
                        }
                    }
                }
            }
        }
    }
}
