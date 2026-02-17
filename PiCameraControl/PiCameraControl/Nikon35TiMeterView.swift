import SwiftUI

/// Nikon 35Ti風アナログメーター（4本針）
struct Nikon35TiMeterView: View {
    let aperture: Double           // f値 (1.4 ~ 22)
    let shutterSpeedUs: Int        // シャッタースピード (μs)
    let iso: Int                   // ISO (100 ~ 6400)
    let exposureCompensation: Double // 露出補正 (-2.0 ~ +2.0)

    var body: some View {
        VStack(spacing: MinimalSpacing.md) {
            // アナログメーターパネル
            meterPanel

            // デジタル表示
            digitalReadout
        }
    }

    // MARK: - Meter Panel

    private var meterPanel: some View {
        ZStack {
            // 楕円形の枠
            Capsule()
                .strokeBorder(MinimalTheme.divider, lineWidth: 1)
                .background(
                    Capsule()
                        .fill(MinimalTheme.Background.surface)
                )
                .frame(width: 320, height: 160)

            // スケール
            scales

            // 針（4本）
            needles

            // 中央ロゴ
            Text("Nikon 35Ti")
                .font(.system(size: 10, weight: .medium, design: .serif))
                .foregroundColor(MinimalTheme.Text.tertiary)
                .offset(y: 40)
        }
        .frame(width: 340, height: 180)
    }

    // MARK: - Scales

    private var scales: some View {
        ZStack {
            // 上部: f値スケール
            HStack(spacing: 8) {
                ForEach([2.8, 4, 5.6, 8, 11, 16, 22], id: \.self) { f in
                    Text(String(format: "%.1f", f))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(MinimalTheme.Text.tertiary)
                }
            }
            .offset(y: -60)

            // 左側: シャッタースピードスケール（縦）
            VStack(spacing: 4) {
                ForEach([3, 7, 10, 2.6, 1.3, 0.7], id: \.self) { ss in
                    Text(String(format: "%.1f", ss))
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .foregroundColor(MinimalTheme.Text.tertiary)
                }
            }
            .offset(x: -140, y: 0)

            // 右側: プログラムモードスケール
            VStack(spacing: 4) {
                Text("P")
                ForEach([10, 20, 30], id: \.self) { p in
                    Text("\(p)")
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                }
            }
            .font(.system(size: 8, weight: .regular, design: .monospaced))
            .foregroundColor(MinimalTheme.Text.tertiary)
            .offset(x: 140, y: -10)

            // 上部中央: 露出補正スケール
            HStack(spacing: 12) {
                ForEach([-2, -1, 0, 1, 2], id: \.self) { ev in
                    Text(ev == 0 ? "0" : "\(ev > 0 ? "+" : "")\(ev)")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(MinimalTheme.Text.secondary)
                }
            }
            .offset(y: -45)
        }
    }

    // MARK: - Needles

    private var needles: some View {
        ZStack {
            // 1. 左の大きい針（f値）180度
            Needle(
                length: 50,
                width: 2,
                color: MinimalTheme.Text.primary,
                angle: apertureAngle
            )
            .offset(x: -40)

            // 2. 右の大きい針（シャッタースピード）180度
            Needle(
                length: 50,
                width: 2,
                color: MinimalTheme.Text.primary,
                angle: shutterSpeedAngle
            )
            .offset(x: 40)

            // 3. 中央上部の短い針（露出補正）70度
            Needle(
                length: 30,
                width: 1.5,
                color: MinimalTheme.Accent.warning,
                angle: exposureCompAngle
            )
            .offset(y: -20)

            // 4. 中央の小さい針（ISO）360度
            Needle(
                length: 20,
                width: 1,
                color: MinimalTheme.Accent.primary,
                angle: isoAngle
            )

            // 中央ドット
            Circle()
                .fill(MinimalTheme.Text.primary)
                .frame(width: 4, height: 4)
        }
    }

    // MARK: - Digital Readout

    private var digitalReadout: some View {
        HStack(spacing: 8) {
            Text("F\(String(format: "%.1f", aperture))")
            Text("•")
            Text(shutterSpeedLabel)
            Text("•")
            Text("ISO\(iso)")
            Text("•")
            Text(String(format: "%+.1fEV", exposureCompensation))
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundColor(MinimalTheme.Text.secondary)
    }

    // MARK: - Angle Calculations

    /// f値の針角度（-90° to +90°）
    private var apertureAngle: Double {
        let stops = log2(aperture / 2.8)
        let maxStops = log2(22.0 / 2.8)
        return -90 + (stops / maxStops) * 180
    }

    /// シャッタースピードの針角度（-90° to +90°）
    private var shutterSpeedAngle: Double {
        let log = log2(Double(shutterSpeedUs) / 125.0)
        return -90 + (log / 13.0) * 180
    }

    /// 露出補正の針角度（-35° to +35°）
    private var exposureCompAngle: Double {
        return exposureCompensation * 17.5
    }

    /// ISOの針角度（0° to 360°、一周）
    private var isoAngle: Double {
        let log = log2(Double(iso) / 100.0)
        return (log / 6.0) * 360
    }

    /// シャッタースピードラベル
    private var shutterSpeedLabel: String {
        let seconds = Double(shutterSpeedUs) / 1_000_000.0

        if seconds >= 1.0 {
            return String(format: "%.0fs", seconds)
        } else if seconds >= 0.1 {
            return String(format: "1/%.0f", 1.0 / seconds)
        } else {
            return String(format: "1/%.0f", 1.0 / seconds)
        }
    }
}

// MARK: - Needle View

struct Needle: View {
    let length: CGFloat
    let width: CGFloat
    let color: Color
    let angle: Double

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: width, height: length)
            .offset(y: -length / 2)
            .rotationEffect(.degrees(angle))
            .animation(MinimalAnimation.slowSpring, value: angle)
    }
}

// MARK: - Preview

struct Nikon35TiMeterView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 24) {
            Nikon35TiMeterView(
                aperture: 5.6,
                shutterSpeedUs: 4000,  // 1/250s
                iso: 400,
                exposureCompensation: 0.3
            )

            Nikon35TiMeterView(
                aperture: 2.8,
                shutterSpeedUs: 125,    // 1/8000s
                iso: 1600,
                exposureCompensation: -1.0
            )
        }
        .padding()
        .background(MinimalTheme.Background.primary)
    }
}
