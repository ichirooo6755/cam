#!/bin/bash

PROJECT_FILE="PiCameraControl/PiCameraControl.xcodeproj/project.pbxproj"

# バックアップ
cp "$PROJECT_FILE" "${PROJECT_FILE}.backup"

# 追加するファイルのリスト
declare -a FILES=(
  "MinimalTheme.swift"
  "PhotoVersion+CoreDataClass.swift"
  "PhotoGroup+CoreDataClass.swift"
  "UnifiedGalleryView.swift"
  "PhotoDetailView.swift"
  "IconGridSelector.swift"
  "Nikon35TiMeterView.swift"
)

# 既存のファイル（PhotoGalleryView.swift）をテンプレートとして使用
TEMPLATE_FILE="PhotoGalleryView.swift"
TEMPLATE_FILE_REF="E00000010000000000000025"
TEMPLATE_BUILD_FILE="E00000010000000000000024"

# 新しいIDを生成（54から開始）
CURRENT_ID=84

for FILE in "${FILES[@]}"; do
  FILE_REF_ID=$(printf "E000000100000000000000%02X" $CURRENT_ID)
  BUILD_FILE_ID=$(printf "E000000100000000000000%02X" $((CURRENT_ID + 1)))
  
  # PBXFileReference セクションに追加
  sed -i '' "/E00000010000000000000025.*PhotoGalleryView\.swift/a\\
\\		$FILE_REF_ID /* $FILE */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = $FILE; sourceTree = \"<group>\"; };
" "$PROJECT_FILE"
  
  # PBXBuildFile セクションに追加
  sed -i '' "/E00000010000000000000024.*PhotoGalleryView\.swift in Sources/a\\
\\		$BUILD_FILE_ID /* $FILE in Sources */ = {isa = PBXBuildFile; fileRef = $FILE_REF_ID /* $FILE */; };
" "$PROJECT_FILE"
  
  # PBXGroup の children に追加
  sed -i '' "/E00000010000000000000025.*PhotoGalleryView\.swift/a\\
\\				$FILE_REF_ID /* $FILE */,
" "$PROJECT_FILE"
  
  # PBXSourcesBuildPhase の files に追加
  sed -i '' "/E00000010000000000000024.*PhotoGalleryView\.swift in Sources/a\\
\\				$BUILD_FILE_ID /* $FILE in Sources */,
" "$PROJECT_FILE"
  
  CURRENT_ID=$((CURRENT_ID + 2))
done

echo "✅ プロジェクトファイルを更新しました"
