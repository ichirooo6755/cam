# 修正計画: ギャラリー・エディタ・設定の3問題

## 問題の概要

### 問題1: ギャラリーのサムネイルが表示されない
- **原因**: `UnifiedGalleryView.swift` の `PhotoCell.loadFromServer()` が TODO のまま未実装
- **流れ**: サーバーから写真一覧(`GET /api/photos`)を取得 → Core DataにPhotoGroup作成 → だがimageDataはnilのまま → `loadThumbnail()` で thumbnail/image 両方nil → `loadFromServer()` に到達 → 中身が空で何もしない
- **Pi側**: `POST /api/photo` に `{"filename": "xxx", "thumbnail": true, "max_dim": 300}` を送ればサムネイルを返す実装は既にある

### 問題2: PhotoEditorの編集バーが見えない（モバイル対応問題）
- **原因**: `PhotoEditorView.swift:1236` で `previewArea.frame(maxWidth: .infinity, maxHeight: .infinity)` が画面スペースを全て占有 → `controlsArea` が画面外に押し出される
- **結果**: アイコングリッドやスライダーが全く見えない

### 問題3: 設定画面のpreviewAreaを削除
- **対象**: `ContentView.swift:291` の `previewArea`（行880-960で定義）
- 撮影結果プレビュー/NO PREVIEW表示のエリア。ユーザーが「入らない」ので削除要求

---

## 修正内容

### 修正1: `UnifiedGalleryView.swift` — サムネイル読み込み実装

**ファイル**: `PiCameraControl/PiCameraControl/UnifiedGalleryView.swift`

`PhotoCell` に `serverIP` を渡し、`loadFromServer()` で `SimpleCameraAPI.downloadPhoto()` を呼び出す：

```swift
// PhotoCell に serverIP プロパティを追加
struct PhotoCell: View {
    @ObservedObject var group: PhotoGroup
    var serverIP: String
    @State private var thumbnailImage: UIImage?
    @State private var isLoading = false
    ...
}

// loadFromServer() を実装
private func loadFromServer() {
    guard let filename = group.id else { return }
    isLoading = true
    Task {
        let api = SimpleCameraAPI(baseURL: "http://\(serverIP):8001")
        if let image = try? await api.downloadPhoto(filename: filename, thumbnail: true, maxDimension: 300) {
            await MainActor.run {
                thumbnailImage = image
                isLoading = false
            }
        } else {
            await MainActor.run {
                isLoading = false
            }
        }
    }
}
```

`photoGrid` での呼び出し側も `PhotoCell(group: group, serverIP: serverIP)` に変更。

### 修正2: `PhotoEditorView.swift` — モバイル対応レイアウト修正

**ファイル**: `PiCameraControl/PiCameraControl/PhotoEditorView.swift`

`body` のレイアウトを `GeometryReader` で画面サイズに応じた比率に変更：

```swift
var body: some View {
    NavigationView {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    previewArea
                        .frame(height: geometry.size.height * 0.4)

                    controlsArea
                        .frame(maxHeight: geometry.size.height * 0.6)
                }
            }
            ...
        }
    }
}
```

これにより:
- プレビュー画像は画面高さの40%
- コントロールエリアは画面高さの60%
- モバイルでもアイコングリッド＋スライダーが確実に表示される

### 修正3: `ContentView.swift` — previewArea 削除

**ファイル**: `PiCameraControl/PiCameraControl/ContentView.swift`

- 行291の `previewArea` の呼び出しを削除
- 行880-960の `previewArea` のプロパティ定義を削除
- 関連する `capturedImage`, `focusPeakingImage`, `enableFocusPeaking` などの状態変数が他で使われていないか確認し、不要なものは削除

---

## 影響範囲
- `UnifiedGalleryView.swift`: PhotoCell のインターフェース変更（serverIPパラメータ追加）
- `PhotoEditorView.swift`: レイアウトのみ変更、機能への影響なし
- `ContentView.swift`: previewArea削除、設定画面がよりコンパクトに
