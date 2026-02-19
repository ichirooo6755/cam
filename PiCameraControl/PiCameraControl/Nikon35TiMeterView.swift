import SwiftUI

/// Nikon 35Ti ANALOG DISPLAY SYSTEM の完全再現
struct Nikon35TiMeterView: View {
    let aperture: Double
    let shutterSpeedUs: Int
    let iso: Int
    let exposureCompensation: Double

    @State private var animAperture: Double = 2.8
    @State private var animShutterUs: Double = 4000
    @State private var animExpComp: Double = 0

    // ダイヤル寸法
    private let dialW: CGFloat = 320
    private let dialH: CGFloat = 170
    private let pad: CGFloat = 5

    var body: some View {
        VStack(spacing: 10) {
            analogDial
            digitalReadout
        }
        .onAppear { doAnimate() }
        .onChange(of: aperture) { _, _ in doAnimate() }
        .onChange(of: shutterSpeedUs) { _, _ in doAnimate() }
        .onChange(of: exposureCompensation) { _, _ in doAnimate() }
    }

    private func doAnimate() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) {
            animAperture = aperture
            animShutterUs = Double(shutterSpeedUs)
            animExpComp = exposureCompensation
        }
    }

    /// カプセル内側の曲線に沿ったx方向の限界値
    private func edgeX(_ y: CGFloat) -> CGFloat {
        let iW = dialW - pad * 2   // 310
        let iH = dialH - pad * 2   // 160
        let r = iH / 2             // 80
        let flat = iW / 2 - r      // 75
        let cy = min(abs(y), r)
        return flat + sqrt(max(0, r * r - cy * cy))
    }

    // MARK: - アナログダイヤル

    private var analogDial: some View {
        ZStack {
            // 外枠（シルバーグラデーション）
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.88, green: 0.88, blue: 0.88),
                            Color(red: 0.66, green: 0.66, blue: 0.68),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)

            // 内側白面
            Capsule()
                .fill(Color(red: 0.965, green: 0.960, blue: 0.948))
                .padding(pad)
            Capsule()
                .strokeBorder(Color(white: 0.50), lineWidth: 0.6)
                .padding(pad)

            // ── コンテンツ ──
            subDialZone
            apertureScaleView
            distanceScaleView
            mainNeedlesView
            pivotDot
            nikonLogo
            expCompBarView
            bottomLabel
        }
        .frame(width: dialW, height: dialH)
        .clipShape(Capsule())
    }

    // MARK: - サブダイヤル（上部、カプセル内部に収まる）

    private var subDialZone: some View {
        ZStack {
            // 背景楕円（小さく、完全に内部に収まる）
            Ellipse()
                .fill(Color(white: 0.935))
                .frame(width: 120, height: 44)
            Ellipse()
                .strokeBorder(Color(white: 0.50), lineWidth: 0.6)
                .frame(width: 120, height: 44)

            // ── ラベル行: AF  L.T.  E  10  P ──
            HStack(spacing: 0) {
                // ▲マーカー + AF
                HStack(spacing: 1) {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 4))
                    Text("AF")
                        .font(.system(size: 5.5, weight: .heavy))
                }
                Spacer()
                Text("L.T.")
                    .font(.system(size: 5.5, weight: .heavy))
                Spacer()
                Text("E")
                    .font(.system(size: 5.5, weight: .heavy))
                Spacer()
                Text("10")
                    .font(.system(size: 5.5))
                Spacer()
                Text("P")
                    .font(.system(size: 6.5, weight: .heavy, design: .serif))
            }
            .foregroundColor(Color(white: 0.06))
            .frame(width: 100)
            .offset(y: -14)

            // ── 目盛り: 10 / 20 / 30 ──
            HStack(spacing: 0) {
                Text("10").frame(maxWidth: .infinity)
                Text("20").frame(maxWidth: .infinity)
                Text("30").frame(maxWidth: .infinity)
            }
            .font(.system(size: 5))
            .foregroundColor(Color(white: 0.28))
            .frame(width: 74)
            .offset(y: -5)

            // ── アイコン（セルフタイマー + フラッシュ） ──
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .strokeBorder(Color(white: 0.20), lineWidth: 0.8)
                        .frame(width: 10, height: 10)
                    Image(systemName: "timer")
                        .font(.system(size: 5.5))
                        .foregroundColor(Color(white: 0.20))
                }
                ZStack {
                    Circle()
                        .strokeBorder(Color(white: 0.20), lineWidth: 0.8)
                        .frame(width: 10, height: 10)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 5))
                        .foregroundColor(Color(white: 0.20))
                }
            }
            .offset(y: 7)

            // ── サブ針 ──
            Rectangle()
                .fill(Color(white: 0.08))
                .frame(width: 0.8, height: 14)
                .offset(y: -7)
                .rotationEffect(.degrees(subNeedleAngle), anchor: .bottom)
        }
        .offset(y: -40)
    }

    // MARK: - f値スケール（右側、カプセル曲線に追従）

    private let fStopData: [(label: String, y: CGFloat)] = [
        ("2.8", -55), ("4", -40), ("5.6", -22),
        ("8",    -2), ("11",  18), ("16",  38), ("22",  57),
    ]

    private var apertureScaleView: some View {
        ZStack {
            ForEach(0..<fStopData.count, id: \.self) { i in
                let stop = fStopData[i]
                let ex = edgeX(stop.y)

                // 目盛り線（カプセル縁から8px内側）
                Rectangle()
                    .fill(Color(white: 0.28))
                    .frame(width: 6, height: 0.6)
                    .offset(x: ex - 8, y: stop.y)

                // 数字（目盛り線のさらに内側、右揃え）
                Text(stop.label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(Color(white: 0.05))
                    .frame(width: 28, alignment: .trailing)
                    .offset(x: ex - 26, y: stop.y)
            }
        }
    }

    // MARK: - 距離スケール（左側、カプセル曲線に追従）

    private let distData: [(m: String, ft: String, y: CGFloat)] = [
        ("5",    "17",    -55),
        ("3",    "10",    -40),
        ("2",    "6.6",   -22),
        ("1",    "3.3",    -2),
        ("0.7",  "2.3",   18),
        ("0.4m", "1.3ft", 38),
    ]

    private var distanceScaleView: some View {
        ZStack {
            ForEach(0..<distData.count, id: \.self) { i in
                let stop = distData[i]
                let ex = edgeX(stop.y)

                // 目盛り線
                Rectangle()
                    .fill(Color(white: 0.28))
                    .frame(width: 6, height: 0.6)
                    .offset(x: -(ex - 8), y: stop.y)

                // ラベル（m 右寄せ + ft 左寄せ）
                HStack(spacing: 1) {
                    Text(stop.m)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Color(white: 0.05))
                        .frame(width: 30, alignment: .trailing)
                    Text(stop.ft)
                        .font(.system(size: 6, weight: .light))
                        .foregroundColor(Color(white: 0.40))
                        .frame(width: 24, alignment: .leading)
                }
                .offset(x: -(ex - 40), y: stop.y)
            }
        }
    }

    // MARK: - メイン針（2本、同一回転軸）

    private let pivotY: CGFloat = 12
    private let needleLen: CGFloat = 80

    private var mainNeedlesView: some View {
        ZStack {
            // f値針（右側を指す）
            singleNeedle(angle: apertureNeedleAngle)
            // SS/距離針（左側を指す）
            singleNeedle(angle: shutterNeedleAngle)
        }
        .offset(y: pivotY)
    }

    @ViewBuilder
    private func singleNeedle(angle: Double) -> some View {
        NeedleTriangle()
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.04), Color(white: 0.35)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 3.5, height: needleLen)
            .offset(y: -(needleLen / 2))
            .rotationEffect(.degrees(angle))
    }

    private var pivotDot: some View {
        Circle()
            .fill(Color(white: 0.06))
            .frame(width: 6, height: 6)
            .offset(y: pivotY)
    }

    // MARK: - Nikonロゴ

    private var nikonLogo: some View {
        Text("Nikon")
            .font(.system(size: 12, weight: .ultraLight, design: .serif))
            .italic()
            .foregroundColor(Color(white: 0.16))
            .offset(y: 32)
    }

    // MARK: - 露出補正バー

    private var expCompBarView: some View {
        VStack(spacing: 2) {
            // +2  +1  ▼  -1  -2
            HStack(spacing: 0) {
                Text("+2").frame(maxWidth: .infinity)
                Text("+1").frame(maxWidth: .infinity)
                Image(systemName: "arrowtriangle.down.fill")
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                Text("−1").frame(maxWidth: .infinity)
                Text("−2").frame(maxWidth: .infinity)
            }
            .font(.system(size: 6.5, weight: .medium))
            .foregroundColor(Color(white: 0.12))
            .frame(width: 86)

            // チェッカーバー + インジケーター
            ZStack {
                Nikon35TiCheckerBar()
                    .frame(width: 86, height: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 1))
                Rectangle()
                    .fill(.red)
                    .frame(width: 3, height: 9)
                    .offset(x: CGFloat(animExpComp) * 21.5)
            }
        }
        .offset(y: 55)
    }

    // MARK: - 下部テキスト

    private var bottomLabel: some View {
        Text("NIKON ANALOG DISPLAY SYSTEM")
            .font(.system(size: 4, weight: .regular, design: .monospaced))
            .foregroundColor(Color(white: 0.42))
            .tracking(0.8)
            .offset(y: 72)
    }

    // MARK: - デジタル表示

    private var digitalReadout: some View {
        HStack(spacing: 8) {
            Text("f/\(apertureText)")
                .monospacedDigit()
            Text("·").foregroundColor(.gray.opacity(0.5))
            Text(shutterText)
                .monospacedDigit()
            Text("·").foregroundColor(.gray.opacity(0.5))
            Text("ISO \(iso)")
                .monospacedDigit()
            if abs(exposureCompensation) > 0.01 {
                Text("·").foregroundColor(.gray.opacity(0.5))
                Text(String(format: "%+.1fEV", exposureCompensation))
                    .monospacedDigit()
            }
        }
        .font(.system(size: 12, weight: .regular))
        .foregroundColor(Color(white: 0.48))
    }

    private var apertureText: String {
        aperture < 10
            ? String(format: "%.1f", aperture)
            : String(format: "%.0f", aperture)
    }

    private var shutterText: String {
        let sec = Double(shutterSpeedUs) / 1_000_000.0
        if sec >= 1 { return String(format: "%.0fs", sec) }
        return "1/\(Int(round(1.0 / sec)))s"
    }

    // MARK: - 角度計算

    /// f値針: f2.8 → -60°, f22 → +60°
    private var apertureNeedleAngle: Double {
        let stops = log2(animAperture / 2.8)
        let maxStops = log2(22.0 / 2.8)
        return -60 + (stops / maxStops) * 120
    }

    /// SS針: 1/2000s(500μs) → +60°, 1s(1000000μs) → -60°
    private var shutterNeedleAngle: Double {
        let minUs = 500.0, maxUs = 1_000_000.0
        let clamped = max(minUs, min(maxUs, animShutterUs))
        let t = log2(clamped / minUs) / log2(maxUs / minUs)
        return 60 - t * 120
    }

    /// サブ針
    private var subNeedleAngle: Double { 0 }
}

// MARK: - 針の形状（テーパー三角形）

struct NeedleTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))       // 先端
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))    // 右根元
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))    // 左根元
        p.closeSubpath()
        return p
    }
}

// MARK: - チェッカーパターンバー

struct Nikon35TiCheckerBar: View {
    var body: some View {
        Canvas { ctx, size in
            let cell: CGFloat = 3
            let cols = Int(ceil(size.width  / cell))
            let rows = Int(ceil(size.height / cell))
            for row in 0..<rows {
                for col in 0..<cols {
                    let dark = (row + col) % 2 == 0
                    ctx.fill(
                        Path(CGRect(
                            x: CGFloat(col) * cell,
                            y: CGFloat(row) * cell,
                            width: cell, height: cell
                        )),
                        with: .color(dark ? Color(white: 0.10) : Color(white: 0.88))
                    )
                }
            }
        }
    }
}

// MARK: - Preview

struct Nikon35TiMeterView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 24) {
            Nikon35TiMeterView(
                aperture: 5.6,
                shutterSpeedUs: 4000,
                iso: 400,
                exposureCompensation: 0.3
            )
            Nikon35TiMeterView(
                aperture: 2.8,
                shutterSpeedUs: 125,
                iso: 1600,
                exposureCompensation: -1.0
            )
        }
        .padding()
        .background(Color(white: 0.93))
    }
}
