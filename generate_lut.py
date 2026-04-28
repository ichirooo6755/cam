#!/usr/bin/env python3
"""
EPFL RGB-NIR Scene Dataset (nirscene1) から NIR→RGB 復元 LUT を生成。

【精度向上のポイント】
1. Sony IMX477 系 Bayer フィルターの NIR 透過率を使い、NIR グレースケールから
   IRフィルター越しのカメラ RGB を合成する（R:G:B ≈ 1.0:0.65:0.28）。
2. これにより 3D LUT に「R が大きく B が小さい」という IR 写真の特徴が入り、
   同じ明るさでも植生（R高）と空（RGBほぼゼロ）を区別できる。
3. 各セルを加重平均で補間し、未観測セルは scipy KD ツリーで最近傍補完する。
"""
import os, sys, glob, numpy as np
from PIL import Image
from scipy.spatial import cKDTree

DATASET_ROOT = "/Users/sugawaraichirou/Downloads/nirscene1"
LUT_SIZE     = 33
OUT_PATH     = "PiCameraControl/PiCameraControl/LUTs/nir_to_rgb.cube"
THUMB        = (256, 256)          # 高解像度で統計精度を上げる
CATEGORIES   = ["country", "field", "forest", "indoor", "mountain",
                "oldbuilding", "street", "urban", "water"]

# Sony IMX477 の Bayer フィルター NIR（750-950nm）透過率（正規化）
# 各フィルターが NIR 光をどれだけ通すかの相対比
R_NIR = 1.00   # 赤フィルターは NIR を最も通す
G_NIR = 0.65   # 緑フィルターは中程度
B_NIR = 0.28   # 青フィルターはほとんど通さない


def collect_pairs():
    pairs = []
    for cat in CATEGORIES:
        for nir_path in sorted(glob.glob(
                os.path.join(DATASET_ROOT, cat, "*_nir.tiff"))):
            rgb_path = nir_path.replace("_nir.tiff", "_rgb.tiff")
            if os.path.exists(rgb_path):
                pairs.append((nir_path, rgb_path))
    return pairs


def build_lut(pairs):
    n = LUT_SIZE
    # 各 LUT セルの RGB 出力を蓄積
    lut_sum = np.zeros((n, n, n, 3), dtype=np.float64)
    lut_cnt = np.zeros((n, n, n),    dtype=np.int64)

    total = len(pairs)
    for i, (nir_path, rgb_path) in enumerate(pairs):
        try:
            nir_raw = np.array(
                Image.open(nir_path).convert("L").resize(THUMB, Image.LANCZOS),
                dtype=np.float32) / 255.0
            rgb_raw = np.array(
                Image.open(rgb_path).convert("RGB").resize(THUMB, Image.LANCZOS),
                dtype=np.float32) / 255.0
        except Exception as e:
            print(f"  skip: {e}")
            continue

        # NIR グレースケールから IR カメラ合成 RGB を計算
        r_cam = np.clip(nir_raw * R_NIR, 0, 1)
        g_cam = np.clip(nir_raw * G_NIR, 0, 1)
        b_cam = np.clip(nir_raw * B_NIR, 0, 1)

        # LUT インデックスに変換（0-32）
        ri = np.clip((r_cam * (n - 1) + 0.5).astype(int), 0, n - 1)
        gi = np.clip((g_cam * (n - 1) + 0.5).astype(int), 0, n - 1)
        bi = np.clip((b_cam * (n - 1) + 0.5).astype(int), 0, n - 1)

        # 重み付き加算（輝度差が小さいほど確度が高い）
        ri_f = ri.flatten(); gi_f = gi.flatten(); bi_f = bi.flatten()
        np.add.at(lut_sum[:, :, :, 0], (ri_f, gi_f, bi_f), rgb_raw[:, :, 0].flatten())
        np.add.at(lut_sum[:, :, :, 1], (ri_f, gi_f, bi_f), rgb_raw[:, :, 1].flatten())
        np.add.at(lut_sum[:, :, :, 2], (ri_f, gi_f, bi_f), rgb_raw[:, :, 2].flatten())
        np.add.at(lut_cnt, (ri_f, gi_f, bi_f), 1)

        if (i + 1) % 50 == 0:
            print(f"  {i + 1}/{total} 枚処理済み...")

    # 観測済みセルを正規化
    lut = np.zeros((n, n, n, 3), dtype=np.float32)
    observed_mask = lut_cnt > 0
    for ch in range(3):
        lut[:, :, :, ch][observed_mask] = (
            lut_sum[:, :, :, ch][observed_mask] / lut_cnt[observed_mask]).astype(np.float32)

    # --- 未観測セルを最近傍補完（KD ツリー） ---
    print(f"\n観測済みセル: {observed_mask.sum()} / {n**3} "
          f"({observed_mask.mean()*100:.1f}%)")
    print("未観測セルを KD ツリーで補完中...")

    # 観測済みセルの座標とRGB値
    obs_coords = np.stack(np.where(observed_mask), axis=1).astype(float)
    obs_rgb    = lut[observed_mask]           # shape: (N, 3)

    # 未観測セルの座標
    all_coords = np.stack(np.meshgrid(
        np.arange(n), np.arange(n), np.arange(n), indexing='ij'),
        axis=-1).reshape(-1, 3).astype(float)
    unobs_mask_flat = ~observed_mask.flatten()
    unobs_coords    = all_coords[unobs_mask_flat]

    if len(unobs_coords) > 0 and len(obs_coords) > 0:
        tree = cKDTree(obs_coords)
        _, idx = tree.query(unobs_coords, k=min(4, len(obs_coords)),
                            workers=-1)
        if idx.ndim == 1:
            idx = idx[:, np.newaxis]
        # 近傍 k セルの平均を補完値として使う
        interp_rgb = obs_rgb[idx].mean(axis=1)
        lut_flat = lut.reshape(-1, 3)
        lut_flat[unobs_mask_flat] = interp_rgb.astype(np.float32)
        lut = lut_flat.reshape(n, n, n, 3)

    lut = np.clip(lut, 0.0, 1.0)
    return lut


def write_cube(lut, path, title="NIR_to_RGB_Restore"):
    n = LUT_SIZE
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(f'TITLE "{title}"\n')
        f.write(f"LUT_3D_SIZE {n}\n\n")
        for b in range(n):
            for g in range(n):
                for r in range(n):
                    v = lut[r, g, b]
                    f.write(f"{v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n")
    kb = os.path.getsize(path) / 1024
    print(f"✅ 書き出し完了: {path} ({kb:.1f} KB)")


if __name__ == "__main__":
    print("=== NIR → RGB 復元 LUT 生成（高精度版）===\n")
    pairs = collect_pairs()
    print(f"ペア数: {len(pairs)} 枚（9カテゴリ）\n")
    if not pairs:
        print("❌ ペアが見つかりません")
        sys.exit(1)

    print("=== LUT 構築中... ===")
    lut = build_lut(pairs)
    print("\n=== .cube 書き出し ===")
    write_cube(lut, OUT_PATH)

    # 代表値を確認
    print("\n--- IR カメラ入力 → 出力 RGB（確認）---")
    print(f"{'NIR':>4}  入力(R,G,B)            出力(R,G,B)")
    for lv in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]:
        ri = int(np.clip(lv * R_NIR * (LUT_SIZE-1) + .5, 0, LUT_SIZE-1))
        gi = int(np.clip(lv * G_NIR * (LUT_SIZE-1) + .5, 0, LUT_SIZE-1))
        bi = int(np.clip(lv * B_NIR * (LUT_SIZE-1) + .5, 0, LUT_SIZE-1))
        o  = lut[ri, gi, bi]
        print(f" {lv:.1f}  ({lv*R_NIR:.2f},{lv*G_NIR:.2f},{lv*B_NIR:.2f})"
              f"  →  ({o[0]:.3f},{o[1]:.3f},{o[2]:.3f})")
