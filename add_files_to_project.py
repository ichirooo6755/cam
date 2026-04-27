#!/usr/bin/env python3
"""
Xcodeプロジェクトに新規Swiftファイルを追加するスクリプト
- PBXFileReference・PBXSourcesBuildPhase 両方未登録のファイル → 両方追加
- PBXFileReference のみ登録済みのファイル → PBXSourcesBuildPhase のみ追加
"""
import re

# PBXFileReference に登録済みだが PBXSourcesBuildPhase 未登録のファイル
# (file_ref_id, filename)
existing_ref_files = [
    ("E00000010000000000000025", "PhotoGalleryView.swift"),
    ("E00000010000000000000031", "EditedPhotosListView.swift"),
]

# 完全未登録のファイル（PBXFileReference・PBXSourcesBuildPhase 両方追加必要）
# ※ HDRComposerView, HDRProcessor, SmartAutoEditEngine, SmartEditFeedbackView は登録済み
new_files = [
    "LUTEngine.swift",
    "LUTStyle.swift",
    "StyleLibraryView.swift",
]

# プロジェクトファイルを読み込み
project_path = "PiCameraControl/PiCameraControl.xcodeproj/project.pbxproj"
with open(project_path, "r") as f:
    content = f.read()

# 既存の最大ID番号を見つける（E00000010000000000000XXX 形式のみ）
ids = re.findall(r"E000000100000000000000([0-9A-Fa-f]+)", content)
max_id = max(int(id_str, 16) for id_str in ids)
print(f"現在の最大ID: 0x{max_id:02X} ({max_id})")

# IDを生成する関数（E00000010000000000000XXX 形式、24文字）
def make_id(n):
    return f"E00000010000000000000{n:03X}"

# 各新規ファイルにIDを割り当て
new_file_entries = []
for i, filename in enumerate(new_files):
    file_ref_id = make_id(max_id + i * 2 + 1)
    build_file_id = make_id(max_id + i * 2 + 2)
    new_file_entries.append({
        "filename": filename,
        "file_ref_id": file_ref_id,
        "build_file_id": build_file_id,
    })

# 既存参照ファイルのビルドID割り当て
next_id = max_id + len(new_files) * 2 + 1
existing_ref_entries = []
for i, (file_ref_id, filename) in enumerate(existing_ref_files):
    build_file_id = make_id(next_id + i)
    existing_ref_entries.append({
        "filename": filename,
        "file_ref_id": file_ref_id,
        "build_file_id": build_file_id,
    })

# --- PBXBuildFile セクションに追加（全ファイル）---
build_file_section = "/* Begin PBXBuildFile section */"
build_file_lines = []
for entry in new_file_entries + existing_ref_entries:
    line = f'\t\t{entry["build_file_id"]} /* {entry["filename"]} in Sources */ = {{isa = PBXBuildFile; fileRef = {entry["file_ref_id"]} /* {entry["filename"]} */; }};'
    build_file_lines.append(line)

build_file_insertion = "\n".join(build_file_lines)
content = content.replace(
    build_file_section,
    f'{build_file_section}\n{build_file_insertion}'
)

# --- PBXFileReference セクションに追加（新規ファイルのみ）---
file_ref_section = "/* Begin PBXFileReference section */"
file_ref_lines = []
for entry in new_file_entries:
    line = f'\t\t{entry["file_ref_id"]} /* {entry["filename"]} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {entry["filename"]}; sourceTree = "<group>"; }};'
    file_ref_lines.append(line)

file_ref_insertion = "\n".join(file_ref_lines)
content = content.replace(
    file_ref_section,
    f'{file_ref_section}\n{file_ref_insertion}'
)

# --- PBXGroup の children に追加（新規ファイルのみ）---
group_pattern = r'(E00000010000000000000017 /\* PiCameraControl \*/ = \{\s+isa = PBXGroup;\s+children = \(\s+)(.*?)(\s+\);)'
def add_to_group(match):
    prefix = match.group(1)
    children = match.group(2)
    suffix = match.group(3)

    new_children_lines = []
    for entry in new_file_entries:
        new_children_lines.append(f'\t\t\t\t{entry["file_ref_id"]} /* {entry["filename"]} */,')

    new_children = "\n".join(new_children_lines)
    return f'{prefix}{children}\n{new_children}{suffix}'

content = re.sub(group_pattern, add_to_group, content, flags=re.DOTALL)

# --- PBXSourcesBuildPhase の files に追加（全ファイル）---
sources_pattern = r'(E0000001000000000000001C /\* Sources \*/ = \{\s+isa = PBXSourcesBuildPhase;\s+buildActionMask = \d+;\s+files = \(\s+)(.*?)(\s+\);)'
def add_to_sources(match):
    prefix = match.group(1)
    files = match.group(2)
    suffix = match.group(3)

    new_files_lines = []
    for entry in new_file_entries + existing_ref_entries:
        new_files_lines.append(f'\t\t\t\t{entry["build_file_id"]} /* {entry["filename"]} in Sources */,')

    new_files_str = "\n".join(new_files_lines)
    return f'{prefix}{files}\n{new_files_str}{suffix}'

content = re.sub(sources_pattern, add_to_sources, content, flags=re.DOTALL)

# ファイルに書き戻し
with open(project_path, "w") as f:
    f.write(content)

print("プロジェクトファイルに以下のファイルを追加しました:")
print("  [新規 PBXFileReference + PBXSourcesBuildPhase]")
for entry in new_file_entries:
    print(f"    - {entry['filename']} (ref={entry['file_ref_id']}, build={entry['build_file_id']})")
print("  [PBXSourcesBuildPhase のみ追加]")
for entry in existing_ref_entries:
    print(f"    - {entry['filename']} (build={entry['build_file_id']})")
