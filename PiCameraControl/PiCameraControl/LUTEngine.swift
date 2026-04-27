import CoreImage
import Foundation

final class LUTEngine {
    static let shared = LUTEngine()

    private var cache: [String: (data: Data, size: Int)] = [:]
    private let lock = NSLock()

    private init() {
        ensureUserLUTDirectory()
    }

    // MARK: - Public

    func load(named name: String) -> (data: Data, size: Int)? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        guard let result = Self.loadFromDisk(name) else { return nil }
        cache[name] = result
        return result
    }

    func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }

    static func apply(_ image: CIImage, data: Data, size: Int, intensity: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return image }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        filter.setValue(size,       forKey: "inputCubeDimension")
        filter.setValue(data,       forKey: "inputCubeData")
        filter.setValue(colorSpace, forKey: "inputColorSpace")
        filter.setValue(image,      forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return image }
        guard intensity < 0.999 else { return output }

        // intensity < 1.0: 元画像とブレンド
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return output }
        let maskColor = CIColor(red: CGFloat(intensity), green: CGFloat(intensity), blue: CGFloat(intensity))
        let mask = CIImage(color: maskColor).cropped(to: image.extent)
        blend.setValue(output, forKey: kCIInputImageKey)
        blend.setValue(image,  forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask,   forKey: kCIInputMaskImageKey)
        return blend.outputImage ?? output
    }

    // MARK: - Style Discovery

    static func availableStyles() -> [LUTStyle] {
        var styles: [LUTStyle] = []

        // 1. アプリバンドル内 LUTs/
        if let bundleURLs = Bundle.main.urls(forResourcesWithExtension: "cube", subdirectory: "LUTs") {
            for url in bundleURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = url.deletingPathExtension().lastPathComponent
                styles.append(LUTStyle(id: name, displayName: formatDisplayName(name), source: .bundle))
            }
        }

        // 2. Documents/LUTs/ — Mac ツールで生成したファイルを配置する場所
        let userDir = userLUTDirectory()
        if let urls = try? FileManager.default
            .contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension.lowercased() == "cube" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent
                if !styles.contains(where: { $0.id == name }) {
                    styles.append(LUTStyle(id: name, displayName: formatDisplayName(name), source: .documents))
                }
            }
        }

        return styles
    }

    static func userLUTDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("LUTs", isDirectory: true)
    }

    // MARK: - Private

    private func ensureUserLUTDirectory() {
        let dir = Self.userLUTDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func loadFromDisk(_ name: String) -> (data: Data, size: Int)? {
        guard let url = resolveURL(name),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseCube(text)
    }

    private static func resolveURL(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "cube", subdirectory: "LUTs") {
            return url
        }
        let user = userLUTDirectory().appendingPathComponent("\(name).cube")
        return FileManager.default.fileExists(atPath: user.path) ? user : nil
    }

    // .cube 形式 → iOS CIColorCubeWithColorSpace 形式に変換
    //
    // .cube: R が最内ループ（最速）, B が最外ループ（最遅）
    //   → linearIndex = r + g*size + b*size²  でエントリ i の (r,g,b) を得る
    //
    // iOS:  B が最内ループ（最速）, R が最外ループ（最遅）
    //   → bufferIndex = b + g*size + r*size²
    //
    // 変換: 入力 (r,g,b) に対し cube[r + g*N + b*N²] → ios[(b + g*N + r*N²) * 4]
    private static func parseCube(_ text: String) -> (data: Data, size: Int)? {
        var size = 0
        var entries: [(r: Float, g: Float, b: Float)] = []

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("TITLE") || line.hasPrefix("DOMAIN") { continue }
            if line.hasPrefix("LUT_3D_SIZE") {
                size = Int(line.split(separator: " ").last ?? "") ?? 0
                continue
            }
            let vals = line.split(separator: " ").compactMap { Float($0) }
            if vals.count == 3 { entries.append((vals[0], vals[1], vals[2])) }
        }

        guard size >= 2, entries.count == size * size * size else { return nil }

        var buffer = [Float](repeating: 0, count: size * size * size * 4)
        for r in 0..<size {
            for g in 0..<size {
                for b in 0..<size {
                    let cubeIdx = r + g * size + b * size * size
                    let iosIdx  = b + g * size + r * size * size
                    let e = entries[cubeIdx]
                    buffer[iosIdx * 4 + 0] = e.r
                    buffer[iosIdx * 4 + 1] = e.g
                    buffer[iosIdx * 4 + 2] = e.b
                    buffer[iosIdx * 4 + 3] = 1.0
                }
            }
        }

        let data = buffer.withUnsafeBytes { Data($0) }
        return (data, size)
    }

    private static func formatDisplayName(_ name: String) -> String {
        // "fujifilm_provia" → "Fujifilm Provia"
        name.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}
