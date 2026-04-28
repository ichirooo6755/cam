#!/usr/bin/env python3
"""
EPFL RGB-NIR Scene Dataset (nirscene1) から NIR→RGB 復元 LUT を生成。

方向: NIR輝度(グレースケール) → 自然なRGB色
用途: IRフィルター越しに撮影した画像を自然な色に復元する。

原理:
  IRフィルター越しのカメラ画像 ≈ NIR輝度でほぼグレースケール（R≈G≈B≈nir）
  → .cube LUT の (r,g,b) インデックスから luminance を求め、
    その輝度帯域で統計的に最も自然な RGB を出力する。

  477ペア × 各画像128²px のピクセル統計から NIR輝度→RGB の分布を推定。
  未学習帯域はスプライン補間で埋める。
"""
import os, glob, numpy as np
from PIL import Image
from scipy.interpolate import interp1d

DATASET_ROOT = "/Users/sugawaraichirou/Downloads/nirscene1"
LUT_SIZE     = 33
OUT_PATH     = "PiCameraControl/PiCameraControl/LUTs/nir_to_rgb.cube"
THUMB        = (128, 128)

# 全カテゴリ（9種）を同等重みで使用
CATEGORIES = ["country", "field", "forest", "indoor", "mountain",
               "oldbuilding", "street", "urban", "water"]


def collect_pairs(root):
    pairs = []
    for cat in CATEGORIES:
        for nir_path in sorted(glob.glob(os.path.join(root, cat, "*_nir.tiff"))):
            rgb_path = nir_path.replace("_nir.tiff", "_rgb.tiff")
            if os.path.exists(rgb_path):
                pairs.append((nir_path, rgb_path))
    return pairs


def build_nir_to_rgb_table(pairs, bins):
    """
    NIR輝度ビン → 平均(R, G, B) の1Dテーブルを構築。
    各ビンに蓄積したRGB値を正規化する。
    """
    rgb_sum = np.zeros((bins, 3), dtype=np.float64)
    rgb_cnt = np.zeros(bins, dtype=np.int64)

    for i, (nir_path, rgb_path) in enumerate(pairs):
        try:
            nir = np.array(
                Image.open(nir_path).convert("L").resize(THUMB, Image.LANCZOS),
                dtype=np.float32) / 255.0
            rgb = np.array(
                Image.open(rgb_path).convert("RGB").resize(THUMB, Image.LANCZOS),
                dtype=np.float32) / 255.0
        except Exception as e:
            print(f"  skip ({e}): {os.path.basename(nir_path)}")
            continue

        # NIR輝度をビンインデックスに変換
        idx = np.clip((nir * (bins - 1) + 0.5).astype(int), 0, bins - 1)
        flat_idx = idx.flatten()
        flat_rgb  = rgb.reshape(-1, 3)

        np.add.at(rgb_sum, flat_idx, flat_rgb)
        np.add.at(rgb_cnt, flat_idx, 1)

        if (i + 1) % 50 == 0:
            print(f"  {i + 1}/{len(pairs)} 枚処理済み...")

    # 平均を計算（未観測ビンは-1でマーク）
    table = np.full((bins, 3), -1.0, dtype=np.float64)
    for b in range(bins):
        if rgb_cnt[b] > 0:
            table[b] = rgb_sum[b] / rgb_cnt[b]

    # 未観測ビンをスプライン補間で補完
    observed = np.where(table[:, 0] >= 0)[0]
    if len(observed) < 2:
        raise ValueError("データが少なすぎて補間できません")

    x_obs = observed.astype(float) / (bins - 1)   # 正規化した輝度
    x_all = np.linspace(0, 1, bins)

    for ch in range(3):
        y_obs = table[observed, ch]
        interp = interp1d(x_obs, y_obs, kind="linear",
                          fill_value=(y_obs[0], y_obs[-1]),
                          bounds_error=False)
        table[:, ch] = np.clip(interp(x_all), 0.0, 1.0)

    return table


def fill_3d_lut(table, size):
    """
    1D NIR→RGB テーブルを 3D LUT に展開する。
    入力 (r,g,b) の luminance を求めて対応する RGB を出力。
    IRフィルター画像は r≈g≈b≈nir のためluminanceがNIR輝度の代替になる。
    """
    n = size
    lut = np.zeros((n, n, n, 3), dtype=np.float32)
    idx_vals = np.linspace(0, 1, n)

    for bi, bv in enumerate(idx_vals):
        for gi, gv in enumerate(idx_vals):
            for ri, rv in enumerate(idx_vals):
                # ITU-R BT.601 luminance
                lum = 0.299 * rv + 0.587 * gv + 0.114 * bv
                bin_idx = int(lum * (len(table) - 1) + 0.5)
                bin_idx = max(0, min(len(table) - 1, bin_idx))
                lut[ri, gi, bi] = table[bin_idx]

    return lut


def write_cube(lut, size, path, title="NIR_to_RGB_Restore"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(f'TITLE "{title}"\n')
        f.write(f"LUT_3D_SIZE {size}\n\n")
        for b in range(size):
            for g in range(size):
                for r in range(size):
                    v = lut[r, g, b]
                    f.write(f"{v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n")
    kb = os.path.getsize(path) / 1024
    print(f"✅ 書き出し完了: {path} ({kb:.1f} KB)")


if __name__ == "__main__":
    print("=== NIR → RGB 復元 LUT 生成 ===")
    pairs = collect_pairs(DATASET_ROOT)
    print(f"ペア数: {len(pairs)} 枚（9カテゴリ）\n")

    if not pairs:
        print("❌ ペアが見つかりません")
        raise SystemExit(1)

    print("=== NIR輝度→RGB テーブル構築中... ===")
    table = build_nir_to_rgb_table(pairs, LUT_SIZE)

    print("\n=== 3D LUT 展開中... ===")
    lut = fill_3d_lut(table, LUT_SIZE)

    print("\n=== .cube ファイル書き出し ===")
    write_cube(lut, LUT_SIZE, OUT_PATH)

    # 代表的な輝度帯のRGB出力を確認
    print("\n--- NIR輝度帯別 出力RGB（確認用）---")
    print(f"{'NIR輝度':>8} | {'R':>6} {'G':>6} {'B':>6}")
    for lv in [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]:
        b = int(lv * (LUT_SIZE - 1) + 0.5)
        v = table[b]
        print(f"  {lv:.1f}    | {v[0]:.4f} {v[1]:.4f} {v[2]:.4f}")
