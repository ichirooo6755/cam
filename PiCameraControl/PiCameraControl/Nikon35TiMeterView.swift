import SwiftUI

/// Nikon 35Ti ANALOG DISPLAY SYSTEM の完全再現
struct Nikon35TiMeterView: View {
    let aperture: Double            // f値 (2.8 ~ 22)
    let shutterSpeedUs: Int         // シャッタースピード (μs)
    let iso: Int                    // ISO (100 ~ 6400)
    let exposureCompensation: Double // 露出補正 (-2.0 ~ +2.0)

    @State private var animAperture: Double = 2.8
    @State private var animShutterUs: Double = 4000
    @State private var animExpComp: Double = 0

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

    // MARK: - アナログダイヤル全体

    private var analogDial: some View {
        ZStack {
            // 外枠（シルバーグラデーション）
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.88, green: 0.88, blue: 0.88),
                            Color(red: 0.68, green: 0.68, blue: 0.70),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.42), radius: 6, x: 0, y: 3)

            // 内側の白い文字盤
            Capsule()
                .fill(Color(red: 0.965, green: 0.962, blue: 0.952))
                .padding(5)

            // 内側境界線
            Capsule()
                .strokeBorder(Color(white: 0.52), lineWidth: 0.6)
                .padding(5)

            // ── コンテンツ ──
            subDialZone          // 上部サブダイヤル
            apertureScale        // 右 f値スケール
            distanceScale        // 左 距離スケール
            mainNeedles          // 2本のメイン針
            needlePivotDot       // 回転軸ドット
            nikonLogo            // Nikonロゴ
            expCompBar           // 露出補正バー
            bottomLabel          // 下部テキスト
        }
        .frame(width: 320, height: 160)
        .clipShape(Capsule())
    }

    // MARK: - 上部サブダイヤルゾーン

    private var subDialZone: some View {
        ZStack {
            // 楕円背景
            Ellipse()
                .fill(Color(red: 0.930, green: 0.928, blue: 0.918))
                .frame(width: 122, height: 56)
            Ellipse()
                .strokeBorder(Color(white: 0.52), lineWidth: 0.7)
                .frame(width: 122, height: 56)

            // ラベル行: AF  L.T.  E  10  P
            HStack(spacing: 0) {
                Text("AF")
                    .font(.system(size: 5.5, weight: .bold))
                Spacer()
                Text("L.T.")
                    .font(.system(size: 5.5, weight: .bold))
                Spacer()
                Text("E")
                    .font(.system(size: 5.5, weight: .bold))
                Spacer()
                Text("10")
                    .font(.system(size: 5.5, weight: .regular))
                Spacer()
                Text("P")
                    .font(.system(size: 6.5, weight: .bold, design: .serif))
            }
            .foregroundColor(Color(white: 0.07))
            .frame(width: 102)
            .offset(y: -19)

            // 目盛り数字（10 / 20 / 30）
            HStack(spacing: 0) {
                Text("10")
                    .offset(x: -32)
                Text("20")
                Text("30")
                    .offset(x: 32)
            }
            .font(.system(size: 5))
            .foregroundColor(Color(white: 0.30))
            .offset(y: -10)

            // アイコン行（セルフタイマー + フラッシュ）
            HStack(spacing: 20) {
                ZStack {
                    Circle()
                        .strokeBorder(Color(white: 0.22), lineWidth: 0.8)
                        .frame(width: 10, height: 10)
                    Image(systemName: "timer")
                        .font(.system(size: 5.5))
                        .foregroundColor(Color(white: 0.22))
                }
                ZStack {
                    Circle()
                        .strokeBorder(Color(white: 0.22), lineWidth: 0.8)
                        .frame(width: 10, height: 10)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 5))
                        .foregroundColor(Color(white: 0.22))
                }
            }
            .offset(y: 5)

            // サブ針（サブダイヤル内の小さい針）
            Rectangle()
                .fill(Color(white: 0.10))
                .frame(width: 0.8, height: 16)
                .offset(y: -8)
                .rotationEffect(.degrees(subNeedleAngle), anchor: .bottom)
        }
        .offset(y: -52)
    }

    // MARK: - f値スケール（右側）

    // 各f値のy座標オフセット
    private let fStops: [(label: String, y: CGFloat)] = [
        ("2.8", -57), ("4", -41), ("5.6", -25),
        ("8",    -6), ("11",  14), ("16",  34), ("22",  57),
    ]

    private var apertureScale: some View {
        ZStack {
            ForEach(fStops, id: \.label) { stop in
                // 目盛り線
                Rectangle()
                    .fill(Color(white: 0.30))
                    .frame(width: 5, height: 0.5)
                    .offset(x: 134, y: stop.y)
                // 数字ラベル
                Text(stop.label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(Color(white: 0.06))
                    .frame(width: 24, alignment: .leading)
                    .offset(x: 121, y: stop.y)
            }
        }
    }

    // MARK: - 距離スケール（左側、m / ft 2列）

    private let distanceStops: [(m: String, ft: String, y: CGFloat)] = [
        ("5",    "17",    -57),
        ("3",    "10",    -41),
        ("2",    "6.6",   -25),
        ("1",    "3.3",    -6),
        ("0.7",  "2.3",   14),
        ("0.4m", "1.3ft", 34),
    ]

    private var distanceScale: some View {
        ZStack {
            ForEach(distanceStops, id: \.m) { stop in
                // 目盛り線
                Rectangle()
                    .fill(Color(white: 0.30))
                    .frame(width: 5, height: 0.5)
                    .offset(x: -134, y: stop.y)
                // ラベル（m 右寄せ / ft 左寄せ）
                HStack(spacing: 2) {
                    Text(stop.m)
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundColor(Color(white: 0.06))
                        .frame(width: 28, alignment: .trailing)
                    Text(stop.ft)
                        .font(.system(size: 6.0, weight: .light))
                        .foregroundColor(Color(white: 0.42))
                        .frame(width: 24, alignment: .leading)
                }
                .offset(x: -108, y: stop.y)
            }
        }
    }

    // MARK: - メイン針（2本、同じ回転軸）

    private let needlePivotY: CGFloat = 22   // 回転軸のy座標（中心から下）
    private let needleLen:    CGFloat = 70   // 針の長さ

    private var mainNeedles: some View {
        ZStack {
            // 右針（f値スケールを指す）
            thinNeedle(angle: apertureNeedleAngle)
            // 左針（シャッタースピード/距離スケールを指す）
            thinNeedle(angle: shutterNeedleAngle)
        }
        .offset(y: needlePivotY)
    }

    @ViewBuilder
    private func thinNeedle(angle: Double) -> some View {
        NeedleTriangle()
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.05), Color(white: 0.38)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 4, height: needleLen)
            .offset(y: -(needleLen / 2))
            .rotationEffect(.degrees(angle))
    }

    private var needlePivotDot: some View {
        Circle()
            .fill(Color(white: 0.08))
            .frame(width: 6, height: 6)
            .offset(y: needlePivotY)
    }

    // MARK: - Nikonロゴ

    private var nikonLogo: some View {
        Text("Nikon")
            .font(.system(size: 13, weight: .ultraLight, design: .serif))
            .italic()
            .foregroundColor(Color(white: 0.18))
            .offset(y: 26)
    }

    // MARK: - 露出補正バー（チェッカーパターン + 動くインジケーター）

    private var expCompBar: some View {
        VStack(spacing: 2) {
            // スケールラベル: +2  +1  ▼  -1  -2
            HStack(spacing: 0) {
                Text("+2").frame(maxWidth: .infinity)
                Text("+1").frame(maxWidth: .infinity)
                Image(systemName: "arrowtriangle.down.fill")
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.red)
                Text("-1").frame(maxWidth: .infinity)
                Text("-2").frame(maxWidth: .infinity)
            }
            .font(.system(size: 6.5, weight: .medium))
            .foregroundColor(Color(white: 0.13))
            .frame(width: 88)

            // チェッカーバー + 赤いインジケーター
            ZStack {
                Nikon35TiCheckerBar()
                    .frame(width: 88, height: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 1))

                Rectangle()
                    .fill(.red)
                    .frame(width: 3, height: 9)
                    .offset(x: CGFloat(animExpComp) * 22.0)
            }
        }
        .offset(y: 52)
    }

    // MARK: - 下部ラベル

    private var bottomLabel: some View {
        Text("NIKON ANALOG DISPLAY SYSTEM")
            .font(.system(size: 4, weight: .regular, design: .monospaced))
            .foregroundColor(Color(white: 0.44))
            .tracking(0.8)
            .offset(y: 68)
    }

    // MARK: - デジタル表示（ダイヤル下）

    private var digitalReadout: some View {
        HStack(spacing: 8) {
            Text("f/\(apertureDisplay)")
                .monospacedDigit()
            Text("·").foregroundColor(.gray.opacity(0.5))
            Text(shutterDisplay)
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

    private var apertureDisplay: String {
        aperture < 10
            ? String(format: "%.1f", aperture)
            : String(format: "%.0f", aperture)
    }

    private var shutterDisplay: String {
        let sec = Double(shutterSpeedUs) / 1_000_000.0
        if sec >= 1 { return String(format: "%.0fs", sec) }
        let denom = Int(round(1.0 / sec))
        return "1/\(denom)s"
    }

    // MARK: - 角度計算

    /// f値針: f2.8 → -55°、f22 → +55°
    private var apertureNeedleAngle: Double {
        let stops = log2(animAperture / 2.8)
        let maxStops = log2(22.0 / 2.8)
        return -55 + (stops / maxStops) * 110
    }

    /// SS針: 1/2000s(500μs) → +55°、1s(1000000μs) → -55°
    private var shutterNeedleAngle: Double {
        let minUs = 500.0, maxUs = 1_000_000.0
        let clamped = max(minUs, min(maxUs, animShutterUs))
        let t = log2(clamped / minUs) / log2(maxUs / minUs)
        return 55 - t * 110
    }

    /// サブ針（現在は中央固定）
    private var subNeedleAngle: Double { 0 }
}

// MARK: - 先端細の三角形針

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
                        with: .color(dark ? Color(white: 0.12) : Color(white: 0.88))
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
