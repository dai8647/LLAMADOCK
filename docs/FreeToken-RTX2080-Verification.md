# FreeToken × RTX 2080 GPU 互換性検証レポート

**検証日**: 2026-08-23
**リポジトリ**: [FlashML-org/FreeToken](https://github.com/FlashML-org/FreeToken)
**対象GPU**: NVIDIA GeForce RTX 2080 (Turing, SM 7.5, 8GB GDDR6)

---

## 結論

**公式サポート外。動作する可能性はあるが、現実的な制限が大きい。**

---

## 検証結果サマリー

| 項目 | RTX 2080 | FreeToken要件 | 判定 |
|------|----------|---------------|------|
| アーキテクチャ | Turing (SM 7.5) | RTX 30/40/50 series (Ampere〜Blackwell) | ❌ |
| VRAM | 8 GB GDDR6 | MoEオフロードでカバー可能 | ⚠️ 可能 |
| PCIe帯域幅 | Gen 3 x16 (~15 GB/s) | Gen 4推奨 (~25 GB/s) | ❌ ボトルネック |
| CUDA / ドライバ | CUDA 12.xまで | driver r580+ (CUDA 13) 必須 | ❌ |
| FP8 / NVFP4 / MXFP4 | 非サポート | モデルの多くがこのフォーマット | ❌ |

---

## 詳細分析

### 1. CUDA 13 必須 — Turing未確認

FreeTokenのインストール要件:
> Linux x86_64, NVIDIA GPU, driver r580+ (CUDA 13)

Turing GPU (RTX 20系列) に対するCUDA 13のサポート状況は未確認。NVIDIAがTuring向けCUDA 13を提供するかどうかが鍵。

### 2. 低精度フォーマットのハードウェア制限

RTX 2080は以下のフォーマットの**ハードウェア加速を持っていない**:
- **FP8**: Hopper/Ada Lovelace (RTX 40+) のみ
- **NVFP4**: Blackwell (RTX 50+) のみ
- **MXFP4**: Blackwell (RTX 50+) のみ

FreeTokenの対応モデルの多くはこれらのフォーマットで提供:
- `nvidia/Qwen3.6-35B-A3B-NVFP4`
- `nvidia/GLM-5.2-NVFP4`
- `nvidia/Gemma-4-26B-A4B-NVFP4`

### 3. PCIe帯域幅の深刻なボトルネック

FreeTokenの核心技术は **CPU↔GPU間のMoEエキスパート転送**。この転送速度がPCIe帯域幅に直接依存。

ペーパル（arXiv: 2608.16157）より:
- RTX 5090 (PCIe 5.0 x16, ~60 GB/s): 140GB転送 = **~2秒**
- RTX 4090 (PCIe 4.0 x16, ~25 GB/s): 140GB転送 = **~5秒**
- RTX 2080 (PCIe 3.0 x16, ~15 GB/s): 140GB転送 = **~9-10秒以上**

この帯域幅不足は体感速度に大きく影響。

### 4. 公式対応GPUに含まれない

READMEに明記された対応GPU:
> Diverse Consumer Hardware: Scales across consumer laptops, gaming desktops, and workstation GPUs, with native support for **NVIDIA RTX 30, RTX 40, and RTX 50 series GPUs**.

Turing (RTX 20系列) は一切言及されていない。

---

## もしRTX 2080で試すなら

### 推奨設定

```bash
# インストール
uv pip install "freetoken[accel]"

# BF16形式のモデルを使用（NVFP4は不可）
ft serve --model ~/models/Qwen3.6-35B-A3B \
  --moe-backend cpu \          # PCIe転送を回避、CPU完結実行
  --dtype bf16                 # FP8/NVFP4は使用不可

# バンド幅プロファイル取得（PCIe制限の確認用）
ft bench bw --dtype bf16
```

### 注意点
- `--moe-backend cpu` はPCIe転送を回避するが、CPU完結実行は帯域幅制限で速度低下
- VRAM 8GBではモデルのKV cache容量が制限される
- CUDA 13がTuringをサポートしているか事前確認が必要

---

## 代替案: RTX 2080で大規模モデルを動かすなら

| エンジン | Turingサポート | MoE対応 | 推奨度 |
|----------|---------------|---------|--------|
| **FreeToken** | ❌ 公式外 | ✅ 最適化済み | △ |
| **llama.cpp** | ✅ 完全サポート | ○ | ◯ |
| **vLLM** | ○ | ✅ | ◯ |
| **KTransformers** | ✅ | ✅ | ◯ |

RTX 2080で大規模MoEモデルを実行するなら、**llama.cpp** が最も安定した選択肢。

---

## 参考文献

- [FreeToken GitHub](https://github.com/FlashML-org/FreeToken)
- [FreeToken Paper (arXiv: 2608.16157)](https://arxiv.org/abs/2608.16157)
- [FreeToken Install Docs](https://github.com/FlashML-org/FreeToken/blob/main/docs/install.md)
- [FreeToken Supported Models](https://github.com/FlashML-org/FreeToken/blob/main/docs/models.md)
