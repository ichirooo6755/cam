#!/usr/bin/env python3
"""
Xcodeプロジェクトに新規Swiftファイルを追加するスクリプト
"""
import re

# 追加するファイル
new_files = [
    "MinimalTheme.swift",
    "PhotoVersion+CoreDataClass.swift",
    "PhotoGroup+CoreDataClass.swift",
    "UnifiedGalleryView.swift",
    "PhotoDetailView.swift",
    "IconGridSelector.swift",
    "Nikon35TiMeterView.swift",
]

# プロジェクトファイルを読み込み
project_path = "PiCameraControl/PiCameraControl.xcodeproj/project.pbxproj"
with open(project_path, "r") as f:
    content = f.read()

# 既存の最大ID番号を見つける
ids = re.findall(r"E000000100000000000000([0-9A-F]{2})", content)
max_id = max(int(id_str, 16) for id_str in ids)

# 各ファイルにIDを割り当て
file_entries = []
for i, filename in enumerate(new_files):
    file_ref_id = f"E{max_id + i * 2 + 1:024X}"
    build_file_id = f"E{max_id + i * 2 + 2:024X}"
    file_entries.append({
        "filename": filename,
        "file_ref_id": file_ref_id,
        "build_file_id": build_file_id,
    })

# PBXBuildFile セクションに追加
build_file_section = "/* Begin PBXBuildFile section */"
build_file_lines = []
for entry in file_entries:
    line = f'\t\t{entry["build_file_id"]} /* {entry["filename"]} in Sources */ = {{isa = PBXBuildFile; fileRef = {entry["file_ref_id"]} /* {entry["filename"]} */; }};'
    build_file_lines.append(line)

build_file_insertion = "\n".join(build_file_lines)
content = content.replace(
    build_file_section,
    f'{build_file_section}\n{build_file_insertion}'
)

# PBXFileReference セクションに追加
file_ref_section = "/* Begin PBXFileReference section */"
file_ref_lines = []
for entry in file_entries:
    line = f'\t\t{entry["file_ref_id"]} /* {entry["filename"]} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {entry["filename"]}; sourceTree = "<group>"; }};'
    file_ref_lines.append(line)

file_ref_insertion = "\n".join(file_ref_lines)
content = content.replace(
    file_ref_section,
    f'{file_ref_section}\n{file_ref_insertion}'
)

# PBXGroup の children に追加
# E00000010000000000000017 のグループを探す
group_pattern = r'(E00000010000000000000017 /\* PiCameraControl \*/ = \{\s+isa = PBXGroup;\s+children = \(\s+)(.*?)(\s+\);)'
def add_to_group(match):
    prefix = match.group(1)
    children = match.group(2)
    suffix = match.group(3)

    new_children_lines = []
    for entry in file_entries:
        new_children_lines.append(f'\t\t\t\t{entry["file_ref_id"]} /* {entry["filename"]} */,')

    new_children = "\n".join(new_children_lines)
    return f'{prefix}{children}\n{new_children}{suffix}'

content = re.sub(group_pattern, add_to_group, content, flags=re.DOTALL)

# PBXSourcesBuildPhase の files に追加
sources_pattern = r'(E0000001000000000000001C /\* Sources \*/ = \{\s+isa = PBXSourcesBuildPhase;\s+buildActionMask = \d+;\s+files = \(\s+)(.*?)(\s+\);)'
def add_to_sources(match):
    prefix = match.group(1)
    files = match.group(2)
    suffix = match.group(3)

    new_files_lines = []
    for entry in file_entries:
        new_files_lines.append(f'\t\t\t\t{entry["build_file_id"]} /* {entry["filename"]} in Sources */,')

    new_files_str = "\n".join(new_files_lines)
    return f'{prefix}{files}\n{new_files_str}{suffix}'

content = re.sub(sources_pattern, add_to_sources, content, flags=re.DOTALL)

# ファイルに書き戻し
with open(project_path, "w") as f:
    f.write(content)

print("✅ プロジェクトファイルに以下のファイルを追加しました:")
for entry in file_entries:
    print(f"  - {entry['filename']}")
