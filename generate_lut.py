#!/usr/bin/env python3
"""
NIR→RGB 復元 LUT 生成（全セル完全カバー版）

問題点の修正:
  旧版: 観測セル0.2% → KDツリーが全部グレーに収束
  新版: NIR輝度ビン×RG比ビンの2D統計テーブルを作り、
        33³全セルを「入力の特性」に応じた出力で埋める。

統計の取り方:
  - 屋外カテゴリ（country/field/forest/mountain/water）のみ使用
    → 植生(NIR高輝度→自然では緑)、空(NIR低輝度→自然では青)の
       対比が明確に出る
  - 輝度ビン(33) × RG比ビン(8) の2Dテーブルで色の特性を保存
  - 全33³セルをテーブルから補間して埋める（空白ゼロ）
"""
import os, sys, glob, numpy as np
from PIL import Image
from scipy.interpolate import RegularGridInterpolator

DATASET_ROOT   = "/Users/sugawaraichirou/Downloads/nirscene1"
LUT_SIZE       = 33
OUT_PATH       = "PiCameraControl/PiCameraControl/LUTs/nir_to_rgb.cube"
THUMB          = (192, 192)
# 屋外カテゴリのみ（植生・空・水の色対比が明確）
OUTDOOR_CATS   = ["country", "field", "forest", "mountain", "water"]
LUMA_BINS      = LUT_SIZE      # 輝度方向
RG_RATIO_BINS  = 8             # R/G比方向（色ヒントとして利用）


def collect_pairs(categories):
    pairs = []
    for cat in categories:
        for nir_path in sorted(glob.glob(
                os.path.join(DATASET_ROOT, cat, "*_nir.tiff"))):
            rgb_path = nir_path.replace("_nir.tiff", "_rgb.tiff")
            if os.path.exists(rgb_path):
                pairs.append((nir_path, rgb_path, cat))
    return pairs


def build_2d_table(pairs):
    """輝度×RG比 の2D統計テーブルを構築"""
    L   = LUMA_BINS
    RG  = RG_RATIO_BINS

    rgb_sum = np.zeros((L, RG, 3), dtype=np.float64)
    rgb_cnt = np.zeros((L, RG),    dtype=np.int64)

    for i, (nir_path, rgb_path, cat) in enumerate(pairs):
        try:
            nir = np.array(
                Image.open(nir_path).convert("L").resize(THUMB, Image.LANCZOS),
                dtype=np.float32) / 255.0
            rgb = np.array(
                Image.open(rgb_path).convert("RGB").resize(THUMB, Image.LANCZOS),
                dtype=np.float32) / 255.0
        except Exception as e:
            print(f"  skip: {e}")
            continue

        # 自然RGB の RG比（色のヒント）
        r_ch = rgb[:, :, 0]
        g_ch = rgb[:, :, 1]
        rg_ratio = r_ch / np.clip(r_ch + g_ch, 1e-4, None)  # 0〜1

        # ビンへマップ
        l_idx  = np.clip((nir          * (L  - 1) + 0.5).astype(int), 0, L  - 1)
        rg_idx = np.clip((rg_ratio     * (RG - 1) + 0.5).astype(int), 0, RG - 1)

        l_f  = l_idx.flatten()
        rg_f = rg_idx.flatten()
        np.add.at(rgb_sum[:, :, 0], (l_f, rg_f), r_ch.flatten())
        np.add.at(rgb_sum[:, :, 1], (l_f, rg_f), g_ch.flatten())
        np.add.at(rgb_sum[:, :, 2], (l_f, rg_f), rgb[:, :, 2].flatten())
        np.add.at(rgb_cnt,          (l_f, rg_f), 1)

        if (i + 1) % 30 == 0:
            print(f"  {i + 1}/{len(pairs)} 枚処理済み...")

    # 正規化
    table = np.zeros((L, RG, 3), dtype=np.float32)
    for li in range(L):
        for ri in range(RG):
            if rgb_cnt[li, ri] > 0:
                table[li, ri] = rgb_sum[li, ri] / rgb_cnt[li, ri]
            else:
                # 未観測セル → 輝度方向に最近傍を探して補完
                luma_val = li / (L - 1)
                rg_val   = ri / (RG - 1)
                # 輝度ベースでニュートラルな値を補完
                table[li, ri] = [luma_val, luma_val * 0.95, luma_val * 0.9]

    coverage = (rgb_cnt > 0).sum()
    print(f"\n観測済みテーブルセル: {coverage}/{L*RG} ({coverage/(L*RG)*100:.1f}%)")
    return table


def fill_lut_from_table(table):
    """
    2Dテーブルから33³全セルを埋める。
    入力(r,g,b) → 輝度L と RG比を計算 → テーブルルックアップ
    """
    n  = LUT_SIZE
    L  = LUMA_BINS
    RG = RG_RATIO_BINS

    # テーブルを RegularGridInterpolator で補間可能にする
    l_axis  = np.linspace(0, 1, L)
    rg_axis = np.linspace(0, 1, RG)

    interp_r = RegularGridInterpolator((l_axis, rg_axis), table[:, :, 0],
                                        method='linear', bounds_error=False,
                                        fill_value=None)
    interp_g = RegularGridInterpolator((l_axis, rg_axis), table[:, :, 1],
                                        method='linear', bounds_error=False,
                                        fill_value=None)
    interp_b = RegularGridInterpolator((l_axis, rg_axis), table[:, :, 2],
                                        method='linear', bounds_error=False,
                                        fill_value=None)

    # 33³ グリッド全セルのクエリ点を作成
    idx = np.linspace(0, 1, n)
    rr, gg, bb = np.meshgrid(idx, idx, idx, indexing='ij')  # shape: (n,n,n)

    # 輝度 (ITU-R BT.601)
    luma = 0.299 * rr + 0.587 * gg + 0.114 * bb
    # RG比
    rg_ratio = rr / np.clip(rr + gg, 1e-4, None)

    pts = np.stack([luma.flatten(), rg_ratio.flatten()], axis=1)

    out_r = interp_r(pts).reshape(n, n, n)
    out_g = interp_g(pts).reshape(n, n, n)
    out_b = interp_b(pts).reshape(n, n, n)

    lut = np.clip(np.stack([out_r, out_g, out_b], axis=-1), 0.0, 1.0).astype(np.float32)
    return lut


def write_cube(lut, path, title="NIR_to_RGB_Restore"):
    n = LUT_SIZE
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(f'TITLE "{title}"\n')
        f.write(f"LUT_3D_SIZE {n}\n\n")
        # .cube 形式: R が最内ループ
        for b in range(n):
            for g in range(n):
                for r in range(n):
                    v = lut[r, g, b]
                    f.write(f"{v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n")
    kb = os.path.getsize(path) / 1024
    print(f"✅ {path} ({kb:.1f} KB)")


if __name__ == "__main__":
    print("=== NIR → RGB 復元 LUT（全セルカバー版）===\n")
    pairs = collect_pairs(OUTDOOR_CATS)
    print(f"屋外ペア数: {len(pairs)} 枚\n")
    if not pairs:
        print("❌ データが見つかりません")
        sys.exit(1)

    print("=== 2D統計テーブル構築 ===")
    table = build_2d_table(pairs)

    print("\n=== 33³ LUT 展開 ===")
    lut = fill_lut_from_table(table)

    print("=== .cube 書き出し ===")
    write_cube(lut, OUT_PATH)

    print("\n--- 確認: NIR入力 → 出力RGB ---")
    n = LUT_SIZE
    print(f"{'入力(R,G,B)':20} {'出力(R,G,B)'}")
    for L in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]:
        i = int(L * (n - 1) + .5)
        v = lut[i, i, i]   # グレー入力（NIR画像の典型）
        print(f"  ({L:.1f},{L:.1f},{L:.1f})            "
              f"→ ({v[0]:.3f}, {v[1]:.3f}, {v[2]:.3f})")
