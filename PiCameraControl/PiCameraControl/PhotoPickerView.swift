import SwiftUI
import PhotosUI

#if canImport(UIKit)
import UIKit
#endif

/// 写真ライブラリから画像をインポートするピッカー
struct PhotoPickerView: View {
    @Binding var isPresented: Bool
    let onImageSelected: (UIImage) -> Void

    @State private var selectedItem: PhotosPickerItem?
    @State private var isLoading = false

    var body: some View {
        NavigationView {
            VStack {
                PhotosPicker(
                    selection: $selectedItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 60))
                            .foregroundColor(.red.opacity(0.9))

                        Text("写真を選択")
                            .font(.title3.weight(.bold))
                            .foregroundColor(.white)

                        Text("編集したい写真をライブラリから選択してください")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
                .onChange(of: selectedItem) { newItem in
                    guard let newItem = newItem else { return }
                    loadImage(from: newItem)
                }

                if isLoading {
                    ProgressView("読み込み中...")
                        .progressViewStyle(CircularProgressViewStyle(tint: .red))
                        .padding()
                }
            }
            .background(Color(red: 0.15, green: 0.15, blue: 0.17))
            .navigationTitle("写真をインポート")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        isPresented = false
                    }
                    .foregroundColor(.red.opacity(0.9))
                }
            }
        }
    }

    private func loadImage(from item: PhotosPickerItem) {
        isLoading = true

        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let uiImage = UIImage(data: data) else {
                    isLoading = false
                    return
                }

                await MainActor.run {
                    onImageSelected(uiImage)
                    isPresented = false
                    isLoading = false
                }
            } catch {
                print("画像の読み込みに失敗: \(error)")
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }
}
