"""Video helpers: last-frame extraction, size probe, PyAV concat (extend/upscale/concat)."""

import json
import os
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# ---- 動画の続き（延長）/ アップスケール / 結合 -------------------------
# 続きもの: 完成動画の最後の1フレームを PyAV で抜き出し、次の生成の
# first_frame（I2V）にすることで前作から自然に続く動画を作る。
# アップスケール: ComfyUI の LoadVideo→GetVideoComponents→RealESRGAN x4→
# ImageScale（2x/4x 目標サイズ）→CreateVideo（元音声を再mux）→SaveVideo。
# 結合: 複数セグメントを PyAV でデコード→1本の mp4 に再エンコード。
# いずれもシステム ffmpeg 不要（PyAV が FFmpeg ライブラリを内蔵）。
UPSCALE_WORKFLOW = os.path.join(REPO, "h3_workflow_upscale.json")
UPSCALE_MODEL_NAME = "RealESRGAN_x4plus.pth"
NODE_UP_LOADVIDEO = "1"    # LoadVideo: file（ComfyUI input/ 内の動画）
NODE_UP_SCALE = "5"        # ImageScale: 目標サイズ（2x/4x）


def _comfy_root():
    return os.environ.get("LLAMADOCK_COMFY_ROOT", r"C:\Users\dai86\Documents\ComfyUI")


def _extract_last_frame(video_path):
    """動画の最後の1フレームを PNG で ComfyUI input/ に保存し、そのファイル名を返す。"""
    import av
    in_dir = os.path.join(_comfy_root(), "input")
    os.makedirs(in_dir, exist_ok=True)
    container = av.open(video_path)
    try:
        stream = container.streams.video[0]
        last = None
        for frame in container.decode(stream):
            last = frame
        if last is None:
            raise ValueError("動画にフレームがありません")
        img = last.to_image()
        name = "h3_ext_{}.png".format(int(time.time() * 1000) % 10**13)
        img.save(os.path.join(in_dir, name))
        return name
    finally:
        container.close()


def _video_size(video_path):
    """(width, height) of the first video stream."""
    import av
    container = av.open(video_path)
    try:
        s = container.streams.video[0]
        return s.codec_context.width, s.codec_context.height
    finally:
        container.close()


def _concat_videos(paths):
    """動画ファイルを順に結合して ComfyUI output/ に mp4 で保存し、ファイル名を返す。

    全セグメント同一解像度が前提（異なれば ValueError）。映像は 24fps・
    h264 再エンコード、音声は aac でつなぐ（H3 の動画は全て 24fps・音声付き）。
    """
    import av
    from fractions import Fraction
    dims = [_video_size(p) for p in paths]
    if len(set(dims)) > 1:
        raise ValueError("解像度が異なる動画は結合できません（同じモードで生成した動画を結合してください）")
    w, h = dims[0]
    out_dir = os.path.join(_comfy_root(), "output")
    os.makedirs(out_dir, exist_ok=True)
    name = "h3_joined_{}.mp4".format(int(time.time() * 1000) % 10**13)
    out_path = os.path.join(out_dir, name)
    out = av.open(out_path, mode="w")
    try:
        vs = out.add_stream("h264", rate=24)
        vs.width = w
        vs.height = h
        vs.pix_fmt = "yuv420p"
        vs.bit_rate = 8_000_000
        vs.time_base = Fraction(1, 24)
        audio_stream = None
        vi = 0
        ai = 0
        for p in paths:
            c = av.open(p)
            try:
                vstream = c.streams.video[0]
                astream = c.streams.audio[0] if c.streams.audio else None
                if audio_stream is None and astream is not None:
                    audio_stream = out.add_stream("aac", rate=astream.rate or 44100)
                    audio_stream.time_base = Fraction(1, astream.rate or 44100)
                for frame in c.decode(vstream):
                    frame = frame.reformat(format="yuv420p")
                    frame.pts = vi
                    vi += 1
                    for pkt in vs.encode(frame):
                        out.mux(pkt)
                if astream is not None and audio_stream is not None:
                    for frame in c.decode(astream):
                        frame.pts = ai
                        ai += frame.samples
                        for pkt in audio_stream.encode(frame):
                            out.mux(pkt)
            finally:
                c.close()
        for pkt in vs.encode(None):
            out.mux(pkt)
        if audio_stream is not None:
            for pkt in audio_stream.encode(None):
                out.mux(pkt)
    finally:
        out.close()
    return name


# Standard ports (must match tools\h3-chat.ps1 / select-model.ps1)
#
# The planning LLM runs in one of two modes:
#   gpu    (default since 2026-10-08): a large GGUF (27B) on GPU (-ngl all),
#                     port 8191. Started on demand for the planning phase
#                     only and killed before every ComfyUI generation, so
#                     the planner and the video model never fight over VRAM.
#   cpu    (LLAMADOCK_PLAN_GPU=0): a small GGUF on CPU (-ngl 0), port 8190,
#                     always-on. The dedicated Qwen3.5-4B was deleted - this
#                     mode only makes sense when a small planner is reinstalled.
#
# The GPU planner model is NOT hardcoded: it is auto-selected from the GGUFs
# installed under .lmstudio\models (scan_plan_models) and can be switched at
# runtime from the UI dropdown (GET/POST /api/plan-models). Env vars
# LLAMADOCK_PLAN_MODEL / LLAMADOCK_PLAN_MMPROJ still win when set.


__all__ = ['HERE', 'REPO', 'UPSCALE_WORKFLOW', 'UPSCALE_MODEL_NAME', 'NODE_UP_LOADVIDEO', 'NODE_UP_SCALE', '_comfy_root', '_extract_last_frame', '_video_size', '_concat_videos']
