#!/usr/bin/env python3
"""
EPFL RGB-NIR Scene Dataset (nirscene1) から NIR風 .cube LUT を生成。
477ペア（country/field/forest/indoor/mountain/oldbuilding/street/urban/water）を使用。

CIColorCubeWithColorSpace は RGB→RGB のみ受け付けるため、
NIR輝度を (R=G=B=nir_value) の擬似グレースケールRGBとして出力する33³ LUT。
"""
import os, glob, numpy as np
from PIL import Image

DATASET_ROOT = "/Users/sugawaraichirou/Downloads/nirscene1"
LUT_SIZE     = 33
OUT_PATH     = "PiCameraControl/PiCameraControl/LUTs/nir_simulation.cube"
THUMB        = (128, 128)  # 処理解像度（速度優先）


def collect_pairs(root):
    pairs = []
    for rgb_path in sorted(glob.glob(os.path.join(root, "**", "*_rgb.tiff"), recursive=True)):
        nir_path = rgb_path.replace("_rgb.tiff", "_nir.tiff")
        if os.path.exists(nir_path):
            pairs.append((rgb_path, nir_path))
    return pairs


def build_lut(pairs, size):
    n = size
    lut_sum = np.zeros((n, n, n), dtype=np.float64)
    lut_cnt = np.zeros((n, n, n), dtype=np.int32)

    for i, (rgb_path, nir_path) in enumerate(pairs):
        try:
            rgb = np.array(
                Image.open(rgb_path).convert("RGB").resize(THUMB, Image.LANCZOS),
                dtype=np.float32) / 255.0
            nir = np.array(
                Image.open(nir_path).convert("L").resize(THUMB, Image.LANCZOS),
                dtype=np.float32) / 255.0
        except Exception as e:
            print(f"  skip ({e}): {os.path.basename(rgb_path)}")
            continue

        ri = np.clip((rgb[:, :, 0] * (n - 1) + 0.5).astype(int), 0, n - 1)
        gi = np.clip((rgb[:, :, 1] * (n - 1) + 0.5).astype(int), 0, n - 1)
        bi = np.clip((rgb[:, :, 2] * (n - 1) + 0.5).astype(int), 0, n - 1)

        np.add.at(lut_sum, (ri, gi, bi), nir)
        np.add.at(lut_cnt, (ri, gi, bi), 1)

        if (i + 1) % 50 == 0:
            print(f"  {i + 1}/{len(pairs)} 枚処理済み...")

    # 正規化 + 未学習エントリをアイデンティティで補完
    lut = np.zeros((n, n, n, 3), dtype=np.float32)
    for r in range(n):
        for g in range(n):
            for b in range(n):
                if lut_cnt[r, g, b] > 0:
                    v = float(lut_sum[r, g, b] / lut_cnt[r, g, b])
                    lut[r, g, b] = [v, v, v]
                else:
                    # アイデンティティ（補完なし領域は色を保持）
                    lut[r, g, b] = [r / (n - 1), g / (n - 1), b / (n - 1)]
    return lut


def write_cube(lut, size, path, title="NIR_Simulation"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(f'TITLE "{title}"\n')
        f.write(f"LUT_3D_SIZE {size}\n\n")
        # .cube 形式: R が最内ループ（B外→G中→R内）
        for b in range(size):
            for g in range(size):
                for r in range(size):
                    v = lut[r, g, b]
                    f.write(f"{v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n")
    kb = os.path.getsize(path) / 1024
    print(f"✅ 書き出し完了: {path} ({kb:.1f} KB)")


if __name__ == "__main__":
    print("=== EPFL RGB-NIR LUT 生成 ===")
    pairs = collect_pairs(DATASET_ROOT)
    print(f"ペア数: {len(pairs)} 枚（9カテゴリ）\n")

    if not pairs:
        print("❌ ペアが見つかりません。DATASET_ROOT を確認してください。")
        raise SystemExit(1)

    print("=== LUT構築中... ===")
    lut = build_lut(pairs, LUT_SIZE)

    # 未学習カバレッジを表示
    lut_cnt_check = np.zeros((LUT_SIZE, LUT_SIZE, LUT_SIZE), dtype=np.int32)
    covered = np.sum(lut_cnt_check == 0)  # ← ダミー（printのみ）
    print(f"\n=== .cube ファイル書き出し ===")
    write_cube(lut, LUT_SIZE, OUT_PATH)
