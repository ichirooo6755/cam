import SwiftUI
import CoreData

#if canImport(UIKit)
import UIKit
#endif

struct EditedPhotosListView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \EditedPhoto.createdAt, ascending: false)],
        animation: .default
    )
    private var photos: FetchedResults<EditedPhoto>

    @State private var selectedPhoto: EditedPhoto?
    @State private var showPhotoDetail: Bool = false
    @State private var detailPhoto: EditedPhoto?

    var body: some View {
        NavigationView {
            Group {
                if photos.isEmpty {
                    emptyStateView
                } else {
                    photosList
                }
            }
            .navigationTitle("編集済み写真")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $selectedPhoto) { photo in
            if let image = photo.image {
                PhotoEditorView(originalImage: image)
                    .environment(\.managedObjectContext, viewContext)
            }
        }
        .sheet(isPresented: $showPhotoDetail) {
            if let photo = detailPhoto {
                EditedPhotoDetailView(photo: photo)
                    .environment(\.managedObjectContext, viewContext)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("編集済み写真がありません")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("PhotoEditorで写真を編集して保存すると、ここに表示されます")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var photosList: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 150), spacing: 12)
            ], spacing: 12) {
                ForEach(photos) { photo in
                    photoCell(photo)
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func photoCell(_ photo: EditedPhoto) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // サムネイル画像
            if let thumbnail = photo.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 150)
                    .clipped()
                    .cornerRadius(12)
            } else if let image = photo.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 150)
                    .clipped()
                    .cornerRadius(12)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))
                    .frame(height: 150)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                    )
            }

            // 情報セクション
            VStack(alignment: .leading, spacing: 4) {
                // 日時
                Text(photo.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)

                // 評価（星）
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { index in
                        Image(systemName: index <= photo.userRating ? "star.fill" : "star")
                            .font(.caption2)
                            .foregroundColor(index <= photo.userRating ? .yellow : .gray)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            detailPhoto = photo
            showPhotoDetail = true
        }
        .contextMenu {
            Button(role: .destructive) {
                deletePhoto(photo)
            } label: {
                Label("削除", systemImage: "trash")
            }

            Button {
                if let image = photo.image {
                    saveToPhotoLibrary(image)
                }
            } label: {
                Label("写真に保存", systemImage: "square.and.arrow.down")
            }
        }
    }

    private func deletePhoto(_ photo: EditedPhoto) {
        withAnimation {
            viewContext.delete(photo)
            do {
                try viewContext.save()
            } catch {
                print("Failed to delete photo: \(error)")
            }
        }
    }

    private func saveToPhotoLibrary(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }
}

// MARK: - EditedPhotoDetailView

struct EditedPhotoDetailView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var photo: EditedPhoto
    @State private var showShareSheet = false
    @State private var imageToShare: UIImage?

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // 画像表示
                    if let image = photo.image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // 評価・情報エリア
                    VStack(spacing: 16) {
                        Divider()

                        // 評価（星）
                        VStack(spacing: 8) {
                            Text("この編集を評価")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)

                            HStack(spacing: 12) {
                                ForEach(1...5, id: \.self) { index in
                                    Button {
                                        updateRating(index)
                                    } label: {
                                        Image(systemName: index <= photo.userRating ? "star.fill" : "star")
                                            .font(.title2)
                                            .foregroundColor(index <= photo.userRating ? .yellow : .gray)
                                    }
                                }
                            }
                        }

                        // 日時
                        Text(photo.createdAt.formatted(date: .long, time: .shortened))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // 設定プレビュー（LUTスタイル）
                        if let settings = photo.settings {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    if !settings.lutStyleName.isEmpty {
                                        settingBadge("LUT", settings.lutStyleName)
                                        settingBadge("強度", String(format: "%.0f%%", settings.lutIntensity * 100))
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.vertical, 16)
                    .background(Color(.systemBackground).opacity(0.95))
                }
            }
            .navigationTitle("写真詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            if let image = photo.image {
                                imageToShare = image
                                showShareSheet = true
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }

                        Button(role: .destructive) {
                            deletePhoto()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let image = imageToShare {
                ShareSheet(items: [image])
            }
        }
    }

    private func settingBadge(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
    }

    private func updateRating(_ rating: Int) {
        photo.userRating = Int16(rating)
        do {
            try viewContext.save()
        } catch {
            print("Failed to update rating: \(error)")
        }
    }

    private func deletePhoto() {
        viewContext.delete(photo)
        do {
            try viewContext.save()
            dismiss()
        } catch {
            print("Failed to delete photo: \(error)")
        }
    }
}

// MARK: - Preview

struct EditedPhotosListView_Previews: PreviewProvider {
    static var previews: some View {
        EditedPhotosListView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
