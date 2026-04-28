#!/usr/bin/env python3
"""LUTs/ フォルダを folder reference として pbxproj に追加"""
import re

project_path = "PiCameraControl/PiCameraControl.xcodeproj/project.pbxproj"
with open(project_path, "r") as f:
    content = f.read()

# 既存の最大Eベース IDを取得
ids = re.findall(r'E00000010000000000000([0-9A-Fa-f]{3})', content)
max_id = max(int(x, 16) for x in ids) if ids else 0x100

folder_ref_id  = f"E00000010000000000000{max_id + 1:03X}"
build_file_id  = f"E00000010000000000000{max_id + 2:03X}"

# 二重登録チェック
if "LUTs" in content:
    print("⚠️  LUTs はすでに登録されています。スキップします。")
    raise SystemExit(0)

# PBXFileReference に folder reference を追加
file_ref_section = "/* Begin PBXFileReference section */"
folder_ref_line = (
    f'\t\t{folder_ref_id} /* LUTs */ = '
    f'{{isa = PBXFileReference; lastKnownFileType = folder; '
    f'path = LUTs; sourceTree = "<group>"; }};'
)
content = content.replace(
    file_ref_section,
    f'{file_ref_section}\n{folder_ref_line}'
)

# PBXBuildFile に追加（Copy Bundle Resources 用）
build_file_section = "/* Begin PBXBuildFile section */"
build_file_line = (
    f'\t\t{build_file_id} /* LUTs in Resources */ = '
    f'{{isa = PBXBuildFile; fileRef = {folder_ref_id} /* LUTs */; }};'
)
content = content.replace(
    build_file_section,
    f'{build_file_section}\n{build_file_line}'
)

# PBXGroup の PiCameraControl グループに追加
group_pattern = (
    r'(E00000010000000000000017 /\* PiCameraControl \*/ = \{\s+'
    r'isa = PBXGroup;\s+children = \()(.*?)(\s+\);)'
)
def add_to_group(m):
    return (m.group(1) + m.group(2)
            + f'\n\t\t\t\t{folder_ref_id} /* LUTs */,'
            + m.group(3))
content = re.sub(group_pattern, add_to_group, content, flags=re.DOTALL)

# PBXResourcesBuildPhase に追加
resources_pattern = (
    r'(E0000001000000000000001B /\* Resources \*/ = \{\s+'
    r'isa = PBXResourcesBuildPhase;\s+buildActionMask = \d+;\s+files = \()(.*?)(\s+\);)'
)
def add_to_resources(m):
    return (m.group(1) + m.group(2)
            + f'\n\t\t\t\t{build_file_id} /* LUTs in Resources */,'
            + m.group(3))
content = re.sub(resources_pattern, add_to_resources, content, flags=re.DOTALL)

with open(project_path, "w") as f:
    f.write(content)

print(f"✅ LUTs フォルダを folder reference として追加しました")
print(f"   FileRef ID : {folder_ref_id}")
print(f"   BuildFile ID: {build_file_id}")
