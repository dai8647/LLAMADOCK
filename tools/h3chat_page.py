"""Embedded chat UI page (HTML + CSS + JS) served on /. Data only."""

import json
import os
import random
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

HTML = """<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MiniMax H3 チャット動画生成</title>
<style>
  :root { --bg:#0b0e14; --panel:#12161f; --panel2:#1a2029; --line:#242c3a;
          --text:#e8eaf0; --muted:#8b93a3; --accent:#38bdf8; --accent2:#3b82f6;
          --ok:#34d399; --err:#f87171; --warn:#fbbf24;
          --grad:linear-gradient(135deg,#22d3ee,#3b82f6); }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--text);
         font-family:"Segoe UI", "Noto Sans JP", sans-serif; height:100vh;
         display:flex; flex-direction:column; }

  /* ---- header ---- */
  header { padding:12px 20px; border-bottom:1px solid var(--line);
           display:flex; align-items:center; gap:14px;
           background:linear-gradient(180deg,rgba(34,211,238,.05),transparent); }
  header h1 { font-size:16px; margin:0; font-weight:700; letter-spacing:.3px; }
  header .sub { color:var(--muted); font-size:12px; }
  #status-dot { width:9px; height:9px; border-radius:50%; background:#555; margin-left:auto;
                box-shadow:0 0 0 3px rgba(255,255,255,.03); }
  #status-dot.ok { background:var(--ok); box-shadow:0 0 8px rgba(52,211,153,.7); }
  #status-dot.down { background:var(--err); box-shadow:0 0 8px rgba(248,113,113,.7); }

  /* ---- sidebar (past sessions, ChatGPT-style) ---- */
  #app { flex:1; display:flex; min-height:0; }
  #sidebar { width:250px; min-width:250px; border-right:1px solid var(--line);
             background:var(--panel); display:flex; flex-direction:column;
             padding:10px; gap:10px; }
  #sidebar.hidden { display:none; }
  #btn-newchat { background:var(--grad); color:#fff; border:none; border-radius:10px;
                 padding:10px 12px; font-size:13px; font-weight:700; cursor:pointer; }
  #sess-list { flex:1; overflow-y:auto; display:flex; flex-direction:column; gap:4px; }
  .sessitem { padding:8px 28px 8px 10px; border-radius:10px; cursor:pointer;
              border:1px solid transparent; position:relative; }
  .sessitem:hover { background:var(--panel2); }
  .sessitem.active { background:var(--panel2); border-color:var(--accent); }
  .sessitem .sesstitle { font-size:12px; line-height:1.4; overflow:hidden;
                         text-overflow:ellipsis; white-space:nowrap; }
  .sessitem .sesstime { font-size:10px; color:var(--muted); margin-top:2px; }
  .sessitem .sessdel { position:absolute; top:6px; right:6px; display:none;
                       background:transparent; border:none; color:var(--muted);
                       padding:2px 5px; font-size:12px; border-radius:6px; cursor:pointer; }
  .sessitem:hover .sessdel { display:block; }
  .sessitem .sessdel:hover { color:var(--err); background:rgba(248,113,113,.12); }
  #sess-empty { color:var(--muted); font-size:11px; padding:6px 4px; }
  #btn-sidebar { background:transparent; border:1px solid var(--line); color:var(--text);
                 border-radius:8px; padding:5px 10px; font-size:14px; cursor:pointer; }
  #btn-sidebar:hover { background:var(--panel2); filter:none; }

  /* ---- chat area ---- */
  main { flex:1; overflow-y:auto; padding:18px 20px; min-width:0; }
  .msg { max-width:80%; padding:11px 15px; border-radius:14px; margin-bottom:12px;
         font-size:14px; line-height:1.55; white-space:pre-wrap; word-break:break-word; }
  .user { background:linear-gradient(135deg,#1e3a5f,#243252); margin-left:auto;
          border:1px solid #2c4a72; border-bottom-right-radius:4px; }
  .bot  { background:var(--panel); border:1px solid var(--line); border-bottom-left-radius:4px; }
  .bot .meta { color:var(--muted); font-size:11px; margin-bottom:6px; }
  .bot .err { color:var(--err); }
  .bot video { width:100%; max-width:520px; border-radius:10px; background:#000; display:block; margin-top:8px; }
  .bot img { width:100%; max-width:520px; border-radius:10px; background:#000; display:block; margin-top:8px; }
  .bot .path { color:var(--muted); font-size:11px; margin-top:6px; word-break:break-all; }
  .row { display:flex; gap:8px; margin-top:10px; flex-wrap:wrap; }
  .row button.ok { background:var(--ok); color:#0b2b1c; }
  .row button.rev { background:var(--warn); color:#3a2400; }
  .row button.small { background:transparent; color:var(--muted); border:1px solid var(--line); }

  /* ---- shutdown banner ---- */
  #shutdown-box { display:none; border-top:2px solid var(--ok); background:#0e241a;
                  padding:10px 20px; font-size:13px; }
  #shutdown-box .meta { color:var(--muted); font-size:11px; margin-bottom:6px; }
  #shutdown-box button { padding:8px 14px; font-size:12px; margin-right:8px; }
  #shutdown-box button.warn { background:var(--err); }

  /* ---- footer: stacked rows, input always full width ---- */
  footer { border-top:1px solid var(--line); padding:12px 16px 14px;
           display:flex; flex-direction:column; gap:10px;
           background:linear-gradient(180deg,transparent,rgba(34,211,238,.04)); }
  .ft-row { display:flex; align-items:center; gap:10px; flex-wrap:wrap; }

  /* segment control (mode pills) */
  .seg { display:flex; gap:3px; background:var(--panel); border:1px solid var(--line);
         border-radius:12px; padding:3px; flex:1; min-width:0; }
  .segbtn { flex:1; min-width:0; }
  .segbtn input { display:none; }
  .segbtn span { display:block; text-align:center; font-size:11px; color:var(--muted);
                 padding:6px 4px; border-radius:9px; cursor:pointer; line-height:1.3;
                 transition:background .15s, color .15s; white-space:nowrap;
                 overflow:hidden; text-overflow:ellipsis; }
  .segbtn span:hover { color:var(--text); background:var(--panel2); }
  .segbtn input:checked + span { background:var(--grad); color:#fff; font-weight:600; }
  .segbtn small { display:block; font-size:9px; opacity:.75; font-weight:400; }

  /* length selector */
  #lenbox { display:flex; align-items:center; gap:6px; font-size:12px; color:var(--muted);
            white-space:nowrap; }
  #lenbox select { background:var(--panel); color:var(--text); border:1px solid var(--line);
                   border-radius:9px; padding:5px 8px; font:inherit; font-size:12px; outline:none; }

  /* toggle / action row */
  .ft-toggles { display:flex; align-items:center; gap:8px; flex-wrap:wrap; }
  .plan { font-size:12px; color:var(--muted); display:flex; gap:6px; align-items:center;
          cursor:pointer; white-space:nowrap; }
  .plan input { accent-color:var(--accent); }
  .ft-toggles > button, #refpick button { background:transparent; color:var(--accent);
          border:1px solid var(--accent); border-radius:9px; padding:6px 12px;
          font-size:12px; font-weight:600; cursor:pointer; white-space:nowrap; }
  .ft-toggles > button:hover, #refpick button:hover { background:rgba(56,189,248,.12); }
  #btn-reset { display:none; }
  #refpick { display:flex; align-items:center; gap:8px; }
  #ref-sel { color:var(--muted); font-size:11px; overflow:hidden; text-overflow:ellipsis;
             white-space:nowrap; max-width:280px; }

  /* expandable panels (advanced / audio) side by side */
  .ft-panels { display:grid; grid-template-columns:1fr 1fr; gap:10px; }
  @media (max-width:820px) { .ft-panels { grid-template-columns:1fr; } }
  #advset, #audioset { font-size:12px; color:var(--muted); background:var(--panel);
          border:1px solid var(--line); border-radius:12px; padding:8px 12px; }
  #advset summary, #audioset summary { cursor:pointer; font-weight:600; color:var(--text);
          list-style:none; display:flex; align-items:center; gap:6px; }
  #advset summary::-webkit-details-marker, #audioset summary::-webkit-details-marker { display:none; }
  #advset summary::before, #audioset summary::before { content:"▸"; color:var(--accent);
          transition:transform .15s; display:inline-block; }
  #advset[open] summary::before, #audioset[open] summary::before { transform:rotate(90deg); }
  #advset .advgroup { margin-top:8px; }
  #advset label { display:flex; gap:6px; align-items:center; margin-top:4px; cursor:pointer; }
  #planparams select, #planparams input[type=number] { background:var(--panel2); color:var(--text);
          border:1px solid var(--line); border-radius:6px; padding:3px 5px; font-size:11px; }
  #audioset input, #audioset textarea { display:block; width:100%; margin-top:6px;
          background:var(--panel2); color:var(--text); border:1px solid var(--line);
          border-radius:8px; padding:7px 10px; font:inherit; font-size:12px; outline:none; }
  #audioset textarea { height:44px; resize:vertical; }
  #btn-au-auto { padding:8px 14px; font-size:12px; margin-top:8px; background:transparent;
          color:var(--ok); border:1px solid var(--ok); border-radius:8px; cursor:pointer; }
  #au-status { font-size:11px; color:var(--muted); margin-left:8px; }

  /* compose row: textarea + send */
  .ft-compose { display:flex; gap:10px; align-items:flex-end; }
  textarea#input { flex:1; resize:none; height:58px; background:var(--panel); color:var(--text);
          border:1px solid var(--line); border-radius:12px; padding:11px 14px;
          font:inherit; font-size:14px; outline:none; transition:border-color .15s, box-shadow .15s; }
  textarea#input:focus { border-color:var(--accent); box-shadow:0 0 0 3px rgba(56,189,248,.15); }
  .ft-send { display:flex; flex-direction:column; gap:6px; }
  button { background:var(--grad); color:#fff; border:none; border-radius:12px;
           padding:13px 24px; font-size:14px; font-weight:700; cursor:pointer;
           transition:filter .15s, transform .05s; }
  button:hover { filter:brightness(1.12); }
  button:active { transform:translateY(1px); }
  button:disabled { opacity:.45; cursor:default; filter:none; }
  button.warn { background:var(--err); }
  .genplan { display:block; margin-top:10px; background:var(--ok); color:#0b2b1c; }
  .hint { color:var(--muted); font-size:11px; }

  /* 動画プロンプトの日本語説明（何が生成されるか一目でわかるように） */
  .promptja { margin:8px 0; border:1px solid var(--accent); border-radius:8px;
          padding:8px 10px; background:rgba(56,189,248,0.06); }
  .promptja .meta { margin-bottom:4px; }
  .promptja .ja-body { white-space:pre-wrap; word-break:break-word; font-size:13px; line-height:1.6; }

  /* thinking trace */
  details.thinkbox { margin:6px 0; border:1px solid var(--line); border-radius:8px;
          padding:6px 10px; background:rgba(255,255,255,0.02); }
  details.thinkbox summary { cursor:pointer; color:var(--muted); font-size:11px; user-select:none; }
  details.thinkbox pre { white-space:pre-wrap; word-break:break-word; color:var(--muted);
          font-size:11px; margin:6px 0 0; max-height:220px; overflow:auto; }

  /* reference image modal */
  .modal { position:fixed; inset:0; background:rgba(0,0,0,.65); display:none;
           align-items:center; justify-content:center; z-index:50; backdrop-filter:blur(2px); }
  .modal-box { background:var(--panel); border:1px solid var(--line); border-radius:14px;
               padding:16px; width:min(92vw,740px); max-height:82vh; display:flex;
               flex-direction:column; }
  .modal-box .meta { margin-bottom:10px; }
  .modal-box > button { align-self:flex-end; padding:8px 18px; }
  #refgrid { flex:1; overflow-y:auto; display:grid;
             grid-template-columns:repeat(auto-fill,minmax(140px,1fr));
             gap:10px; margin-bottom:12px; }
  .refcard { border:1px solid var(--line); border-radius:10px; overflow:hidden; cursor:pointer;
             background:var(--bg); transition:border-color .15s; position:relative; }
  .refcard:hover { border-color:var(--accent); }
  .refcard.sel { border-color:var(--ok); box-shadow:0 0 0 2px rgba(52,211,153,.35); }
  .refcard img { width:100%; height:90px; object-fit:cover; display:block; background:#000; }
  .refcard .refname { font-size:11px; padding:5px 6px 0; color:var(--text);
                      overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .refcard .refdir { font-size:10px; padding:0 6px 6px; color:var(--muted); }
  .refcard .refbadge { position:absolute; top:4px; left:4px; background:var(--ok); color:#04120c;
                       border-radius:10px; font-size:11px; font-weight:700; padding:1px 8px; }
  .reffoot { display:flex; align-items:center; gap:10px; }
  .reffoot > span { flex:1; }

  /* key-image candidate grid */
  .imggrid { display:grid; grid-template-columns:repeat(auto-fill,minmax(150px,1fr));
             gap:10px; margin-top:8px; }
  .imgcard { border:2px solid var(--line); border-radius:10px; overflow:hidden; cursor:pointer;
             background:var(--bg); transition:border-color .15s; }
  .imgcard:hover { border-color:var(--accent); }
  .imgcard.sel { border-color:var(--ok); box-shadow:0 0 0 2px rgba(52,211,153,.35); }
  .imgcard img { width:100%; height:110px; object-fit:cover; display:block; background:#000; }
  .imgcard .imgname { font-size:10px; padding:4px 6px; color:var(--muted);
                      overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
</style>
</head>
<body>
<header>
  <button id="btn-sidebar" onclick="toggleSidebar()" title="履歴サイドバーを表示/非表示">☰</button>
  <h1>🎬 MiniMax H3 チャット動画生成</h1>
  <span class="sub">企画モード: キー画像（Klein 9B / Qwen-Image）→ 確認 → 動画（H3・4B TE）</span>
  <span id="status-dot" title="ComfyUI 接続状態"></span>
</header>
<div id="app">
<aside id="sidebar">
  <button id="btn-newchat" onclick="newChat()">➕ 新しい企画</button>
  <div id="sess-list"></div>
</aside>
<main id="msgs"></main>
</div>
<div id="shutdown-box">
  <div class="meta">生成完了 ✅ 自動停止まで <b id="countdown">90</b> 秒（GPU・メモリを解放します）</div>
  <button class="warn" onclick="stopAll()">🛑 今すぐすべて終了</button>
  <button onclick="stopComfy()">ComfyUI だけ停止</button>
  <button class="small" onclick="cancelStop()">キャンセル</button>
</div>
<div id="refmodal" class="modal">
  <div class="modal-box">
    <div class="meta">参照画像を選択（ComfyUI の output/・input/ にある画像から・クリックで複数選択・最大 9 枚）</div>
    <div id="refgrid"></div>
    <div class="reffoot">
      <span id="refpick-count" class="hint">0 枚選択中</span>
      <button onclick="applyRefPick()">✅ 参照画像として使う</button>
      <button onclick="closeRefModal()">閉じる</button>
    </div>
  </div>
</div>
<footer>
  <div class="ft-row">
    <div class="seg">
      <label class="segbtn"><input type="radio" name="mode" value="fast" checked><span>最高画質<small>spectrum・約15分</small></span></label>
      <label class="segbtn"><input type="radio" name="mode" value="high"><span>高精度<small>turbo・フル尺 約9分</small></span></label>
      <label class="segbtn"><input type="radio" name="mode" value="fast_quick"><span>高画質<small>spectrum・短尺</small></span></label>
      <label class="segbtn"><input type="radio" name="mode" value="quick"><span>クイック<small>turbo・短尺 2〜4分</small></span></label>
      <!-- lite/quicklite は 32B TE 廃止で high/quick と同一生成になったため非表示の互換スロット
           （旧セッションの DOM 復元だけを担当）。UI からは選べない。 -->
      <label class="segbtn" style="display:none"><input type="radio" name="mode" value="lite"><span>高精度<small>フル尺</small></span></label>
      <label class="segbtn" style="display:none"><input type="radio" name="mode" value="quicklite"><span>クイック<small>短尺</small></span></label>
    </div>
    <div id="lenbox">
      <span>長さ:</span>
      <select id="len-sel" onchange="onLenChange()">
        <option value="">モードの既定</option>
        <option value="5">約5秒</option>
        <option value="10">約10秒</option>
        <option value="15">約15秒</option>
      </select>
      <span id="len-note" class="hint"></span>
    </div>
  </div>
  <div class="ft-toggles">
    <label class="plan"><input type="checkbox" id="planmode"> ✎ 企画モード</label>
    <label class="plan" title="ON のとき、確定したキー画像／選んだ参照画像を使って生成します（使い方は右で選択）"><input type="checkbox" id="refmode"> 🖼 画像モード</label>
    <label class="plan" title="📌 先頭フレーム固定 (I2V): 動画がこの画像から始まる／🏁 最終フレーム固定: 動画がこの画像で終わる／🎭 参照 (R2V): フレームは固定せず同一キャラだけ維持"><span class="hint">画像の使い方:</span>
      <select id="imguse">
        <option value="first" selected>📌 先頭フレーム固定（I2V）</option>
        <option value="last">🏁 最終フレーム固定</option>
        <option value="ref">🎭 参照・キャラ維持（R2V）</option>
      </select>
    </label>
    <div id="refpick">
      <button type="button" onclick="pickRefImage()">🗂 参照画像を選ぶ</button>
      <span id="ref-sel" class="hint">未選択（企画モードで確定したキー画像を使用）</span>
      <button type="button" id="ref-clear" onclick="clearRefImage()" style="display:none" title="参照画像の選択を解除する">✕ 解除</button>
    </div>
    <button type="button" id="btn-reset" onclick="resetPlan()">🔄 新しい企画</button>
    <button type="button" id="btn-manual" onclick="showManualPrompt()">✍ 手動プロンプト</button>
  </div>
  <div class="ft-panels">
    <details id="advset">
      <summary>⚙ 詳細設定（動画モデル・キー画像エンジン・企画 LLM）</summary>
      <div class="advgroup">
        <span class="hint">動画モデル:</span>
            <label><input type="radio" name="dit" value="default" checked> 10Eros NVFP4（高画質・11.7GB・既定）</label>
            <label><input type="radio" name="dit" value="pinkcherry"> PinkCherry int8（旧既定・19.5GB）</label>
      </div>
      <div class="advgroup">
        <span class="hint">品質チューニング（任意・空欄 = 既定値）:</span>
        <label title="参照画像を短辺 2048px で使う（MiniMax H3 の ref_image_size=max）。なりきり精度は最高だが、参照トークンが毎ステップに乗るため数倍遅い。R2V（参照）モードのみ効果。"><input type="checkbox" id="refsize-max"> 🔍 参照画像を高解像度で使う（max・低速・R2V のみ）</label>
        <label>EasyCache 閾値:<input type="number" id="tune-easycache" min="0" max="1" step="0.05" placeholder="0.1" style="width:70px"><span class="hint">高い=速い・粗い（spectrum 系モードには無し）</span></label>
        <label>Turbo LoRA 強度:<input type="number" id="tune-lora" min="0" max="2" step="0.1" placeholder="1.2" style="width:70px"><span class="hint">turbo 系モードのみ</span></label>
        <label>保存 crf:<input type="number" id="tune-crf" min="0" max="51" step="1" placeholder="23" style="width:70px"><span class="hint">低い=高画質・大容量（再エンコード）</span></label>
      </div>
      <div class="advgroup">
        <span class="hint">キー画像:</span>
        <label><input type="radio" name="imgengine" value="kimg" checked> Klein 9B（品質主力・スマホ写真＋NSFW LoRA重ね掛け）</label>
        <label><input type="radio" name="imgengine" value="qimg"> Qwen-Image 2.1 UC（局所描写・検閲なし・高画質）</label>
        <label><input type="radio" name="imgengine" value="qfix"> Qwen 2.1 UC 品質モード（Fix LoRA・破綻しにくい・低速）</label>
      </div>
      <div class="advgroup" id="planmodelset">
        <span class="hint">企画 LLM モデル（導入済みから選択・GPU 固定ではありません）:</span>
        <label>モデル:<select id="p-model" onchange="selectPlanModel()" style="max-width:420px"></select></label>
        <span id="p-model-status" class="hint"></span>
      </div>
      <div class="advgroup">
        <span class="hint" title="キャラライブラリ（config/characters/）に登録した人物の顔・髪・体型を固定します。次のキー画像から効き、画像を固定すれば動画 (I2V/R2V) も自動的に同じ人物になります。解除するまで有効。">キャラ固定（任意・次のキー画像から有効）:</span>
        <label>キャラ:<select id="char-pin" onchange="onCharPinChange()" style="max-width:280px"><option value="">なし（毎回自由に決める）</option></select></label>
        <span id="char-pin-status" class="hint"></span>
      </div>
      <div class="advgroup" id="planparams">
        <span class="hint">企画 LLM パラメータ:</span>
        <label>KV キー:<select id="p-ctk" onchange="sendPlanSettings()"><option value="q8_0" selected>q8_0</option><option value="q4_0">q4_0</option><option value="f16">f16</option><option value="none">なし</option></select></label>
        <label>KV 値:<select id="p-ctv" onchange="sendPlanSettings()"><option value="q4_0" selected>q4_0</option><option value="q8_0">q8_0</option><option value="f16">f16</option><option value="none">なし</option></select></label>
        <label><input type="checkbox" id="p-fa" checked onchange="sendPlanSettings()"> フラッシュアテンション</label>
        <label>推論:<select id="p-reasoning" onchange="sendPlanSettings()"><option value="low" selected>low</option><option value="medium">medium</option><option value="off">off</option><option value="xhigh">xhigh</option></select></label>
        <label>予算:<input type="number" id="p-budget" value="768" min="0" max="32768" step="256" style="width:70px" onchange="sendPlanSettings()"></label>
      </div>
    </details>
    <details id="audioset">
      <summary>🎙 音声・セリフ設定（任意）</summary>
      <input type="text" id="au-voice" placeholder="声: 例：低めの落ち着いた声・息を含むささやき">
      <textarea id="au-dialogue" placeholder="セリフ: 例：今夜は帰らないで"></textarea>
      <input type="text" id="au-sfx" placeholder="効果音・環境音: 例：夜の雨音・布擦れ・遠い車の音">
      <input type="text" id="au-music" placeholder="音楽: 例：ゆっくりしたピアノ">
      <button type="button" id="btn-au-auto" onclick="autoAudio()">🎙 自動で考える（LLM）</button>
      <span id="au-status" class="hint"></span>
    </details>
  </div>
  <div class="ft-compose">
    <textarea id="input" placeholder="作りたい動画を言葉で書いてください。例：夕焼けの海岸で柴犬が波打ち際を走る映像"></textarea>
    <div class="ft-send">
      <button id="send" onclick="send()">生成 ▶</button>
      <button id="cancel" class="warn" style="display:none" onclick="cancelCurrent()">✕ キャンセル</button>
    </div>
  </div>
</footer>
<script>
const $ = s => document.querySelector(s);
let busy = false;
let jobCancelled = false;
let curJobId = null;
let lastImgPrompt = null;
let lastFinalPrompt = null;
// 参照画像リスト（順序付き・[0] が主参照 = <Picture 1>）。企画モードで確定した
// キー画像は 1 要素だけ入る。🗂 ピッカーで複数（最大 9 枚）選べる。
let refImages = [];
// ピッカーが開いている間の一時選択（「適用」で refImages に反映）
let refPickerSelection = [];
let planStage = "chat";   // chat -> image -> video -> done
// キャラ固定の選択（config/characters/<id>.json の id・空 = 固定なし）。
// セッションごとに uiSnapshot に載せて復元する。
let pinnedChar = "";
let charLib = [];
// 参照モードで「どんな動画にするか」を相談中かどうか。最初の1ターンだけ
// 企画 LLM に"いきなり FINAL_PROMPT を作らず相談して"という指示を付ける。
let refConsultActive = false;
let shutdownTimer = null;
let shutdownLeft = 0;
// セッション履歴（サイドバー）: 今表示中のセッション id
// （null = まだ一度も保存されていない新しい企画）
let activeSessionId = null;
let lastSavedJson = "";   // 自動保存の重複排除（中身 unchanged なら送らない）
let curJobKind = null;    // "video" | "image" | "upscale" — セッション復元時のジョブ再開用
// 動画の続きもの（セグメント連鎖）: extendVideo で始まり、続きセグメントが
// 完成するたびに伸びる。2 本以上で「結合」ボタンが出る。
let segmentChain = [];    // 順序付きファイル名リスト
let extendFrom = null;    // 今生成中の続きセグメントの「元の動画」

function addMsg(kind, html) {
  const el = document.createElement("div");
  el.className = "msg " + kind;
  el.innerHTML = html;
  $("#msgs").appendChild(el);
  $("#msgs").scrollTop = $("#msgs").scrollHeight;
  return el;
}

function esc(s) {
  return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
}

// Collapsible "thinking" trace from the planning LLM (reasoning_content).
function thinkHtml(t) {
  if (!t) return "";
  return '<details class="thinkbox"><summary>💭 企画 LLM の考え中（' + t.length + '字）</summary><pre>' + esc(t) + "</pre></details>";
}

function setBusy(b) {
  busy = b;
  $("#send").disabled = b;
  $("#cancel").style.display = b ? "" : "none";
}

async function checkServer() {
  try {
    const r = await fetch("/api/queue");
    if (r.ok) { $("#status-dot").className = "ok"; return true; }
  } catch (e) {}
  $("#status-dot").className = "down";
  return false;
}
setInterval(checkServer, 5000);
checkServer();
loadPlanModels();

function ditValue() {
  const el = document.querySelector('input[name="dit"]:checked');
  return el ? el.value : "default";
}

function audioSpec() {
  return {
    dialogue: $("#au-dialogue").value.trim(),
    voice: $("#au-voice").value.trim(),
    sfx: $("#au-sfx").value.trim(),
    music: $("#au-music").value.trim()
  };
}

// 「長さ」ドロップダウン: 空ならモードの既定、選べばその秒数（H3 の
// フレームグリッドへはサーバー側でスナップされる）。
function lenValue() {
  const v = $("#len-sel").value;
  return v ? parseInt(v, 10) : null;
}function onLenChange() {
  const v = $("#len-sel").value;
  $("#len-note").textContent = v ? "（約" + v + "秒で生成）" : "";
}

// Send planner KV/FA/reasoning settings to the backend.
function sendPlanSettings() {
  const ctk = $("#p-ctk");
  const ctv = $("#p-ctv");
  const fa = $("#p-fa");
  const re = $("#p-reasoning");
  const rb = $("#p-budget");
  if (!ctk) return;
  fetch("/api/plan-settings", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({
      ctk: ctk.value, ctv: ctv.value,
      fa: fa.checked, reasoning_effort: re.value,
      reasoning_budget: parseInt(rb.value, 10) || 768
    })
  }).catch(() => {});
}

// 企画 LLM モデル: 導入済み GGUF をサーバーから取得してドロップダウン表示。
// 選ぶと実行中の企画 LLM が停止し、次のメッセージから新モデルで起動する。
async function loadPlanModels() {
  const sel = $("#p-model");
  if (!sel) return;
  try {
    const r = await fetch("/api/plan-models");
    const j = await r.json();
    if (!r.ok) return;
    sel.innerHTML = "";
    (j.models || []).forEach(m => {
      const o = document.createElement("option");
      o.value = m.path;
      o.dataset.mmproj = m.mmproj || "";
      o.dataset.gpu = m.gpu ? "1" : "0";
      o.textContent = m.label + "（" + m.size_gb + "GB・" + (m.gpu ? "GPU" : "CPU") + (m.vision ? "・視覚" : "") + "）";
      if (j.current && m.path === j.current.path) o.selected = true;
      sel.appendChild(o);
    });
    const st = $("#p-model-status");
    if (st) {
      if (j.external) st.textContent = "外部エンドポイント使用中。モデルを選ぶと外部を停止して新しいモデルで起動します。";
      else if (!j.current || !j.current.path) st.textContent = "⚠ 企画 LLM のモデルが見つかりません（LM Studio に GGUF を追加してください）";
      else st.textContent = j.running ? "稼働中。切り替えると次回メッセージから反映。" : "停止中。次のメッセージで自動起動。";
    }
  } catch (e) {}
}

async function selectPlanModel() {
  const sel = $("#p-model");
  const o = sel.options[sel.selectedIndex];
  if (!o) return;
  const st = $("#p-model-status");
  if (st) st.textContent = "切り替え中（稼働中の企画 LLM を停止します）…";
  try {
    const r = await fetch("/api/plan-model", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({path: o.value, mmproj: o.dataset.mmproj || null, gpu: o.dataset.gpu === "1"})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    if (st) st.textContent = j.note || "切り替えました。";
  } catch (e) {
    if (st) st.textContent = "切替エラー: " + e.message;
  }
}




async function autoAudio() {
  const btn = $("#btn-au-auto");
  if (btn.disabled) return;
  const concept = lastFinalPrompt || lastImgPrompt || $("#input").value.trim();
  if (!concept) {
    $("#au-status").textContent = "生成したい映像の説明を先に入力してください。";
    return;
  }
  btn.disabled = true;
  $("#au-status").textContent = "企画 LLM が音響を考え中…";
  try {
    const r = await fetch("/api/audio", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({text: concept})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    const a = j.audio || {};
    let filled = 0;
    if (a.voice) { $("#au-voice").value = a.voice; filled++; }
    if (a.dialogue) { $("#au-dialogue").value = a.dialogue; filled++; }
    if (a.sfx) { $("#au-sfx").value = a.sfx; filled++; }
    if (a.music) { $("#au-music").value = a.music; filled++; }
    $("#au-status").textContent = filled ? ("✅ 自動提案を反映（" + filled + "項目・編集可）") : "提案が取得できませんでした。";
  } catch (e) {
    $("#au-status").textContent = "エラー: " + e.message;
  }
  btn.disabled = false;
}

async function pickRefImage() {
  try {
    const r = await fetch("/api/refimages");
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    const grid = $("#refgrid");
    grid.innerHTML = "";
    // 既存の選択を引き継ぐ（後から追加・削除できるように）
    refPickerSelection = refImages.slice();
    const imgs = j.images || [];
    for (const img of imgs) {
      const c = document.createElement("div");
      c.className = "refcard";
      c.dataset.path = img.path;
      c.innerHTML =
        '<img src="/api/refimg?path=' + encodeURIComponent(img.path) + '" loading="lazy">' +
        '<div class="refname">' + esc(img.name) + '</div>' +
        '<div class="refdir">' + esc(img.dir) + '</div>' +
        '<div class="refbadge" style="display:none"></div>';
      c.onclick = () => toggleRefPick(c, img.path);
      grid.appendChild(c);
    }
    if (!imgs.length) {
      grid.innerHTML = '<div class="hint">参照に使える画像がありません。ComfyUI output/ に生成結果、input/ に手動配置の画像を置いてください。</div>';
    }
    refreshRefGridMarks();
    updateRefPickCount();
    $("#refmodal").style.display = "flex";
  } catch (e) {
    alert("参照画像一覧の取得に失敗: " + e.message);
  }
}
// カードクリックで選択トグル。順序が <Picture N> の番号になる。
function toggleRefPick(card, path) {
  const i = refPickerSelection.indexOf(path);
  if (i >= 0) {
    refPickerSelection.splice(i, 1);
  } else {
    if (refPickerSelection.length >= 9) {
      alert("参照画像は最大 9 枚までです（MiniMax H3 の上限）");
      return;
    }
    refPickerSelection.push(path);
  }
  refreshRefGridMarks();
  updateRefPickCount();
}
function refreshRefGridMarks() {
  const grid = $("#refgrid");
  for (const c of grid.children) {
    if (!c.dataset || !c.dataset.path) continue;
    const idx = refPickerSelection.indexOf(c.dataset.path);
    const badge = c.querySelector ? c.querySelector(".refbadge") : null;
    if (idx >= 0) {
      c.className = "refcard sel";
      if (badge) { badge.style.display = ""; badge.textContent = String(idx + 1); }
    } else {
      c.className = "refcard";
      if (badge) { badge.style.display = "none"; badge.textContent = ""; }
    }
  }
}
function updateRefPickCount() {
  const n = refPickerSelection.length;
  $("#refpick-count").textContent = n ? n + " 枚選択中（番号が <Picture N> の順番）" : "0 枚選択中";
}
// ピッカーの選択を確定する。0 枚で適用 = 選択解除。
function applyRefPick() {
  refImages = refPickerSelection.slice();
  // 新しい参照画像を選んだ＝新しい企画の始まりなので、相談フラグをリセット
  refConsultActive = false;
  if (refImages.length) {
    // 🗂 からの選択は「このキャラを使って動画を作りたい」意味なので、
    // 既定の使い方は参照（R2V）。先頭フレーム固定にしたければ UI で切替可。
    $("#imguse").value = "ref";
    updateRefSel();
    const clr = $("#ref-clear");
    if (clr) clr.style.display = "inline-block";
  } else {
    clearRefImage();
  }
  closeRefModal();
}
function closeRefModal() { $("#refmodal").style.display = "none"; }
// フッターの選択表示を更新する（1 枚目ファイル名 + 枚数）。
function updateRefSel() {
  const sel = $("#ref-sel");
  if (!refImages.length) {
    sel.textContent = "未選択（企画モードで確定したキー画像を使用）";
    return;
  }
  const name = refImages[0].split(/[\\/]/).pop();
  sel.textContent = refImages.length === 1
    ? name
    : name + " ほか計 " + refImages.length + " 枚（<Picture 1.." + refImages.length + ">）";
}

// チャット指示（「高画質で/長めに」等）による設定上書きが効いているとき、
// 生成開始メッセージに追記して「知らない間に別の設定で生成されていた」を防ぐ。
function overrideNote(bot, j) {
  if (!bot || !j || !j.override_label) return;
  const n = document.createElement("div");
  n.className = "hint";
  n.textContent = "⚙ チャット指示を反映中: " + j.override_label + "（UI のモード/長さより優先・解除は 🔄 新しい企画）";
  bot.appendChild(n);
}
// このモードでは効かなかった品質チューニング設定（fast 系の EasyCache 無し等）を
// サーバーから受け取って表示する（サイレントに無視しない）。
function tuneNote(bot, j) {
  if (!bot || !j || !(j.tune_ignored || []).length) return;
  const n = document.createElement("div");
  n.className = "hint";
  n.textContent = "⚙ 反映されなかった設定: " + j.tune_ignored.join("、");
  bot.appendChild(n);
}
// フレーム固定（first/last）に複数画像が選ばれている場合、使われるのは
// 1 枚目だけで残りは無視される。その旨を明示する（黙って裏切らない）。
function refUsageNote(bot) {
  if (!bot) return;
  if (refImages.length > 1 && $("#imguse").value !== "ref") {
    const n = document.createElement("div");
    n.className = "hint";
    n.textContent = "⚠ フレーム固定には 1 枚目の参照画像だけ使われます（残り " + (refImages.length - 1) + " 枚は無視・すべて使うには 🎭 参照を選んでください）";
    bot.appendChild(n);
  }
}
// 詳細設定の品質チューニング（空欄 = ワークフロー既定値を送らない）。
function tuneSpec() {
  const t = {};
  const ec = $("#tune-easycache") ? $("#tune-easycache").value.trim() : "";
  const lo = $("#tune-lora") ? $("#tune-lora").value.trim() : "";
  const crf = $("#tune-crf") ? $("#tune-crf").value.trim() : "";
  if (ec) t.easycache = parseFloat(ec);
  if (lo) t.lora = parseFloat(lo);
  if (crf) t.crf = parseFloat(crf);
  return t;
}

// 参照画像の選択を解除する。一度 🗂 で選ぶと refImages が残り、
// 以降の生成が全て勝手に R2V（参照あり）になってしまうため、明示的に
// 解除できる手段が必要（「画像を参照したくないのに参照される」事故の対策）。
function clearRefImage() {
  refImages = [];
  refPickerSelection = [];
  refConsultActive = false;
  updateRefSel();
  const c = $("#ref-clear");
  if (c) c.style.display = "none";
}

async function send() {
  const text = $("#input").value.trim();
  if (!text || busy) return;
  setBusy(true);
  $("#input").value = "";
  addMsg("user", esc(text));
  if ($("#planmode").checked) { plan(text); return; }
  if ($("#refmode").checked && !refImages.length) {
    addMsg("bot", '<div class="meta">参照画像が未設定です。✎ 企画モードでキー画像を確定するか、下部の「🗂 参照画像を選ぶ」から既存の画像を指定してください。</div>');
    setBusy(false);
    return;
  }
  if ($("#refmode").checked) {
    // 画像モードは「どんな動画にするか」を決めずに長時間の生成を始めない。
    // 企画 LLM に画像を見せながら内容を相談し、[FINAL_PROMPT] を
    // ユーザーが確認してから生成する（企画モードと同じ確認フロー）。
    planStage = "video";
    const first = !refConsultActive;
    refConsultActive = true;
    plan(text, first);
    return;
  }
  const bot = addMsg("bot", '<div class="meta">生成中…（モデルロード込みで数分）</div>');
  const mode = document.querySelector('input[name="mode"]:checked').value;
  try {
    jobCancelled = false;
    const r = await fetch("/api/generate", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({
        mode: mode, text: text, dit: ditValue(),
        // 選んだ画像は常に参照される（画像モード checkbox が OFF でも自動有効）。
        // 「画像を入れたのに無視されて無関係な動画ができる」事故の根本対策。
        ref: $("#refmode").checked || refImages.length > 0,
        image: refImages[0] || null, images: refImages,
        image_use: $("#imguse").value,
        ref_size: ($("#refsize-max") && $("#refsize-max").checked) ? "max" : "match",
        tune: tuneSpec(),
        audio: audioSpec(), length: lenValue(),
        ...charPinSpec()
      })
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    overrideNote(bot, j);
    refUsageNote(bot);
    tuneNote(bot, j);
    poll(j.prompt_id, bot);
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
    setBusy(false);
  }
}

async function plan(text, refStart) {
  const meta = refStart
    ? "企画 LLM が参照画像を見て、動画の内容を相談しています…"
    : "企画 LLM が考え中…";
  const bot = addMsg("bot", '<div class="meta">' + meta + "</div>");
  try {
    const r = await fetch("/api/plan", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({text: text, stage: planStage, image: refImages[0] || null, images: refImages, ref_start: !!refStart, ...charPinSpec()})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    let html = '<div class="meta">企画案</div>' + thinkHtml(j.thinking) + esc(j.reply || "（応答なし）");
    if (j.img_prompt) {
      lastImgPrompt = j.img_prompt;
      const revising = (planStage === "image");
      planStage = "image";
      // どんな画像になるか日本語で必ず示す（英語プロンプトだけだと内容が分からない
      // 問題の対策・動画側の「こんな映像になります」と同じ仕組み）。
      if (j.img_prompt_ja) {
        html += '<div class="promptja"><div class="meta">🖼 こんな画像になります</div><div class="ja-body">' + esc(j.img_prompt_ja) + "</div></div>";
      }
      html += '<details class="thinkbox"><summary>📝 英語プロンプト（原文・クリックで表示）</summary><pre style="white-space:pre-wrap;margin:6px 0 0;font-size:12px;">' + esc(j.img_prompt) + '</pre></details>';
      // 修正時も自動で再生成せず、必ずボタンを出す（ユーザーが確認してから
      // 生成を始める）。自動 genImage は kimg（約1分）を勝手に回して
      // 「再生成します…」のまま固まる原因になっていた。
      html += '<button class="genplan" onclick="genImage()">' +
        (revising ? "🖼 このプロンプトで再生成 ▶" : "🖼 キー画像を生成 ▶") + "</button>";
      html += '<div class="hint">画像を確認して OK なら確定、気に入らなければ「🔁 修正する」で修正できます。</div>';
    } else if (j.final_prompt) {
      // Store the prompt in a module variable instead of inlining it into the
      // onclick attribute: prompts may contain double quotes / HTML special
      // characters that would break the inline-JSON escaping.
      lastFinalPrompt = j.final_prompt;
      planStage = "video";
      // どんな映像になるか日本語で必ず示す（英語プロンプトだけだと内容が分からない
      // 問題の対策）。日本語説明を主表示し、英語原文は折りたたみに格納する。
      if (j.final_prompt_ja) {
        html += '<div class="promptja"><div class="meta">🎬 こんな映像になります</div><div class="ja-body">' + esc(j.final_prompt_ja) + "</div></div>";
      }
      html += '<details class="thinkbox"><summary>📝 英語プロンプト（原文・クリックで表示）</summary><pre style="white-space:pre-wrap;margin:6px 0 0;font-size:12px;">' + esc(j.final_prompt) + '</pre></details>';
      html += '<button class="genplan" onclick="genPlanLast()">🎬 この企画で生成 ▶</button>';
    } else if (planStage === "video") {
      // 動画内容の相談中（参照モード開始直後など）。進め方を案内する。
      html += '<div class="hint">LLM の質問に答えて動画の内容を固めてください。「まとめて」「プロンプト確定」で [FINAL_PROMPT] を作ります。' +
        '画質・長さ・向きもチャットで調整できます（例：「もっと高画質で」「長めに」「縦長で」）。' +
        '自分でプロンプトを書きたい場合は下の「✍ 手動プロンプト」から直接入力できます。</div>';
      html += '<button class="genplan" style="background:transparent;color:var(--accent);border:1px solid var(--accent)" onclick="showManualPrompt()">✍ 手動プロンプトで生成する</button>';
    }
    if (j.audio && (j.audio.voice || j.audio.dialogue || j.audio.sfx || j.audio.music)) {
      if (j.audio.voice) $("#au-voice").value = j.audio.voice;
      if (j.audio.dialogue) $("#au-dialogue").value = j.audio.dialogue;
      if (j.audio.sfx) $("#au-sfx").value = j.audio.sfx;
      if (j.audio.music) $("#au-music").value = j.audio.music;
      html += '<div class="meta">🎙 音声・セリフ設定を自動提案しました（下部の設定欄に反映・編集可）</div>';
    }
    bot.innerHTML = html;
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
  }
  setBusy(false);
}

function imgEngine() {
  const el = document.querySelector('input[name="imgengine"]:checked');
  return el ? el.value : "kimg";
}

async function genImage(prevBot) {
  if (!lastImgPrompt) {
    addMsg("bot", '<div class="meta">⚠ 生成する画像プロンプトがありません。企画 LLM に案を出してもらってください。</div>');
    return;
  }
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了するまでお待ちください。</div>');
    return;
  }
  jobCancelled = false;
  const eng = imgEngine();
  const engLabels = {kimg: "Klein 9B", qimg: "Qwen-Image 2.1 UC", qfix: "Qwen 2.1 UC 品質"};
  const label = engLabels[eng] || "画像";
  const bot = prevBot || addMsg("bot", '<div class="meta">' + label + ' でキー画像を生成中…</div>');
  setBusy(true);
  try {
    const r = await fetch("/api/kimg", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({text: lastImgPrompt, engine: eng, ...charPinSpec()})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    pollImage(j.prompt_id, bot);
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
    setBusy(false);
  }
}

async function pollImage(id, bot) {
  if (jobCancelled) return;
  curJobId = id;
  curJobKind = "image";
  try {
    const r = await fetch("/api/status/" + id);
    const j = await r.json();
    if (j.status === "success") {
      const imgs = (j.videos || []).filter(v => v.kind === "image");
      if (!imgs.length) {
        bot.innerHTML = '<div class="meta">エラー</div><div class="err">画像が見つかりませんでした</div>';
        curJobId = null;
        curJobKind = null;
        setBusy(false);
        return;
      }
      // 全候補をギャラリー表示して選べるようにする（最後の1枚だけ問題の修正）
      refImages = [imgs[0].filename];
      updateRefSel();
      let grid = '<div class="imggrid">';
      imgs.forEach((img, i) => {
        grid +=
          '<div class="imgcard' + (i === 0 ? " sel" : "") + '" data-fn="' + esc(img.filename) + '" onclick="pickKeyImage(this)">' +
          '<img src="/api/view?filename=' + encodeURIComponent(img.filename) + '&type=' + encodeURIComponent(img.type || "output") + '">' +
          '<div class="imgname">' + esc(img.filename) + "</div></div>";
      });
      grid += "</div>";
      bot.innerHTML =
        '<div class="meta">キー画像 ✅（' + imgs.length + '枚・クリックで選択）</div>' +
        grid +
        '<div class="row">' +
        '<button class="ok" onclick="confirmImage()">✅ この画像で確定 → 動画を相談</button>' +
        '<button class="rev" onclick="genImage()">🎲 同じプロンプトで引き直す</button>' +
        '<button class="rev" onclick="reviseImage()">🔁 修正する</button>' +
        "</div>";
      planStage = "image";
      curJobId = null;
      curJobKind = null;
      setBusy(false);
      return;
    }
    if (j.status === "error") {
      bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(j.error || "画像生成に失敗しました") + "</div>";
      curJobId = null;
      curJobKind = null;
      setBusy(false);
      return;
    }
    bot.querySelector(".meta").textContent = "キー画像生成中… " + (j.extra || "");
    if (jobCancelled) return;
    setTimeout(() => pollImage(id, bot), 2000);
  } catch (e) {
    if (jobCancelled) return;
    setTimeout(() => pollImage(id, bot), 2000);
  }
}

function pickKeyImage(card) {
  const grid = card.parentElement;
  grid.querySelectorAll(".imgcard").forEach(c => c.classList.remove("sel"));
  card.classList.add("sel");
  refImages = [card.dataset.fn];
  updateRefSel();
}

function reviseImage() {
  planStage = "image";
  $("#input").placeholder = "修正したい点を入力（例：犬を白く、夕焼けをもっと赤く）";
  $("#input").focus();
}

function confirmImage() {
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了してから画像を確定してください。</div>');
    return;
  }
  if (!refImages.length) {
    addMsg("bot", '<div class="meta">⚠ 確定する画像がありません。画像を生成してから選んでください。</div>');
    return;
  }
  // 企画モードで確定したキー画像は「動画の1フレーム目」約束なので、
  // 既定の使い方を先頭フレーム固定 (I2V) にする（参照にしたければ UI で切替可）。
  $("#imguse").value = "first";
  setBusy(true);
  const bot = addMsg("bot", '<div class="meta">企画 LLM と動画の内容を相談中…（Klein 9B はアンロード済み）</div>');
  (async () => {
    try {
      const r = await fetch("/api/plan", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({text: "__CONFIRM_IMAGE__", stage: "video", image: refImages[0] || null})
      });
      const j = await r.json();
      if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
      let html = '<div class="meta">画像を確定 ✅（ここから動画の内容を相談します）</div>' + thinkHtml(j.thinking) + esc(j.reply || "（応答なし）");
      if (j.final_prompt) {
        lastFinalPrompt = j.final_prompt;
        planStage = "video";
        if (j.final_prompt_ja) {
          html += '<div class="promptja"><div class="meta">🎬 こんな映像になります</div><div class="ja-body">' + esc(j.final_prompt_ja) + "</div></div>";
        }
        html += '<details class="thinkbox"><summary>📝 英語プロンプト（原文・クリックで表示）</summary><pre style="white-space:pre-wrap;margin:6px 0 0;font-size:12px;">' + esc(j.final_prompt) + '</pre></details>';
        html += '<button class="genplan" onclick="genPlanLast()">🎬 この企画で生成 ▶</button>';
      } else {
        planStage = "video";
        html += '<div class="hint">LLM の質問に答えて動画の内容を固めてください。「まとめて」「プロンプト確定」で [FINAL_PROMPT] を作ります。' +
          '画質・長さ・向きもチャットで調整できます（例：「もっと高画質で」「長めに」「縦長で」「30秒で」）。' +
          '自分でプロンプトを書きたい場合は下の「✍ 手動プロンプト」から直接入力できます。</div>';
      }
      html += '<button class="genplan" style="background:transparent;color:var(--accent);border:1px solid var(--accent)" onclick="showManualPrompt()">✍ 手動プロンプトで生成する</button>';
      bot.innerHTML = html;
    } catch (e) {
      bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
    }
    setBusy(false);
  })();
}

function showManualPrompt() {
  // 生成中に開けると、🎬 側の busy ガードに当たって「押しても何も起きない」
  // ことになるので、先に開かない。
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了してから「✍ 手動プロンプト」を開いてください。</div>');
    return;
  }
  const bot = addMsg("bot",
    '<div class="meta">✍ 手動プロンプト</div>' +
    '<textarea id="manual-prompt" style="width:100%;height:110px;background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:8px;padding:8px;font:inherit;font-size:13px" placeholder="動画プロンプトを英語で直接入力（例: [Shot 1] The woman turns to the camera and smiles, the camera slowly dollies in...）"></textarea>' +
    '<div class="row"><button class="ok" onclick="useManualPrompt(this)">🎬 このプロンプトで生成 ▶</button></div>');
  bot.querySelector("#manual-prompt").focus();
}

function useManualPrompt(btn) {
  // 手動プロンプト UI は何度でも開けてメッセージが残るため、
  // document.querySelector だと古い（空の）textarea が先にヒットして
  // 無反応になる。必ず自分のメッセージ内の textarea を読む。
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了してから実行してください。</div>');
    return;
  }
  const msg = btn ? btn.closest(".msg") : null;
  const ta = msg ? msg.querySelector("#manual-prompt") : document.querySelector("#manual-prompt");
  const text = ta ? ta.value.trim() : "";
  if (!text) {
    addMsg("bot", '<div class="meta">⚠ プロンプトが空です。上の入力欄に動画プロンプトを書いてから押してください。</div>');
    return;
  }
  lastFinalPrompt = text;
  planStage = "video";
  addMsg("user", "✍ 手動プロンプトで生成: " + text);
  genPlanLast();
}

function imageUseTag() {
  // 生成開始メッセージに「画像がどう使われるか」を明示する。
  // 「いつの間にか別の使い方で生成されていた」を防ぐための表示。
  const use = $("#imguse").value;
  if (use === "first") return "📌 先頭フレーム固定で生成する: ";
  if (use === "last") return "🏁 最終フレーム固定で生成する: ";
  return "🎭 参照モード（R2V）で生成する: ";
}

function genPlanLast() {
  // 無言で return すると「ボタンが動かない」ように見える。必ず理由を表示する。
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了するまでお待ちください。</div>');
    return;
  }
  if (!lastFinalPrompt) {
    addMsg("bot", '<div class="meta">⚠ 生成するプロンプトがありません。「✍ 手動プロンプト」で入力するか、企画を再相談してください。</div>');
    return;
  }
  const finalPrompt = lastFinalPrompt;
  // lastFinalPrompt は消さない: 生成が失敗・キャンセルされたとき、同じボタンで
  // そのままやり直せる必要がある（以前はここで null にしていて、失敗すると
  // 「プロンプトがありません」になり企画の再相談を強要していた。genImage が
  // lastImgPrompt を保持するのと同じ挙動に揃える）。
  setBusy(true);
  const mode = document.querySelector('input[name="mode"]:checked').value;
  // キー画像（refImages）がある場合は checkbox に関係なく画像モード
  const useRef = $("#refmode").checked || refImages.length > 0;
  const tag = useRef ? imageUseTag() : "✅ この企画で生成する: ";
  addMsg("user", tag + finalPrompt);
  const bot = addMsg("bot", '<div class="meta">生成中…（モデルロード込みで数分）</div>');
  doGenerate(mode, finalPrompt, bot);
}

async function doGenerate(mode, text, bot) {
  try {
    jobCancelled = false;
    const r = await fetch("/api/generate", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({
        mode: mode, text: text, dit: ditValue(),
        // 選んだ画像は常に参照される（画像モード checkbox が OFF でも自動有効）。
        // 「画像を入れたのに無視されて無関係な動画ができる」事故の根本対策。
        ref: $("#refmode").checked || refImages.length > 0,
        image: refImages[0] || null, images: refImages,
        image_use: $("#imguse").value,
        ref_size: ($("#refsize-max") && $("#refsize-max").checked) ? "max" : "match",
        tune: tuneSpec(),
        audio: audioSpec(), length: lenValue(),
        ...charPinSpec()
      })
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    overrideNote(bot, j);
    refUsageNote(bot);
    tuneNote(bot, j);
    poll(j.prompt_id, bot);
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
    setBusy(false);
  }
}

async function poll(id, bot, kind) {
  curJobId = id;
  const k = kind || "video";
  curJobKind = k;
  try {
    const r = await fetch("/api/status/" + id);
    const j = await r.json();
    if (j.status === "success") {
      const vids = j.videos || [];
      if (!vids.length) {
        bot.innerHTML = '<div class="meta">エラー</div><div class="err">生成は完了しましたが出力が見つかりませんでした。もう一度お試しください。</div>';
        curJobId = null;
        curJobKind = null;
        setBusy(false);
        return;
      }
      const v = vids[0];
      // 続きセグメントが完成したら連鎖を伸ばす（結合ボタン用）
      if (curJobKind === "video" && extendFrom) {
        segmentChain.push(v.filename);
        extendFrom = null;
      }
      const isUpscale = curJobKind === "upscale";
      bot.innerHTML = '<div class="meta">' + (isUpscale ? "アップスケール完了 ✅" : "完成 ✅") + "</div>" +
        '<video controls autoplay loop muted src="/api/view?filename=' + encodeURIComponent(v.filename) +
        '&type=' + encodeURIComponent(v.type || "output") + '"></video>' +
        '<div class="path">' + esc(v.path) + "</div>" +
        (isUpscale ? "" : videoActionsHtml(v.filename));
      curJobId = null;
      curJobKind = null;
      setBusy(false);
      if (!isUpscale) startShutdown();
      return;
    }
    if (j.status === "error") {
      bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(j.error || "失敗しました") + "</div>";
      curJobId = null;
      curJobKind = null;
      setBusy(false);
      return;
    }
    // still running: refresh the eta text every poll
    const el = Math.floor((j.elapsed_sec || 0) / 60);
    const es = String((j.elapsed_sec || 0) % 60).padStart(2, "0");
    const eta = j.eta_sec || 0;
    let etaTxt;
    if (eta <= (j.elapsed_sec || 0)) etaTxt = "予定より長引いています…";
    else if (eta >= 60) etaTxt = "残り 約" + Math.round(eta / 60) + "分";
    else etaTxt = "残り 約" + eta + "秒";
    bot.querySelector(".meta").textContent =
      "生成中… " + etaTxt + "（経過 " + el + ":" + es + "・待機中: " + j.pending + " 件）";
    if (jobCancelled) return;   // キャンセル済み: ポーリング停止
    // show a cancel button once so a stuck/stale queue item can be cleared
    if (!bot.querySelector(".cancelbtn")) {
      const b = document.createElement("button");
      b.className = "warn small cancelbtn";
      b.textContent = "✕ キャンセル";
      b.onclick = () => cancelJob(id, bot);
      bot.appendChild(b);
    }
    setTimeout(() => poll(id, bot, k), 3000);
  } catch (e) {
    setTimeout(() => poll(id, bot, k), 3000);
  }
}

async function cancelJob(id, bot) {
  jobCancelled = true;
  setBusy(false);
  try {
    await fetch("/api/cancel", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({prompt_id: id})
    });
  } catch (e) {}
  if (curJobId === id) {
    curJobId = null;
    curJobKind = null;
  }
  if (bot) {
    const meta = bot.querySelector(".meta");
    if (meta) meta.textContent = "キャンセルしました（ComfyUI のジョブを中断・削除）";
    const cb = bot.querySelector(".cancelbtn");
    if (cb) cb.remove();
  }
}

async function cancelCurrent() {
  if (!curJobId) {
    // busy 中でもジョブ ID が無い = 企画 LLM の応答待ち。無言で返すと
    // 「キャンセルが効かない」ように見えるので、理由を表示する。
    addMsg("bot", '<div class="meta">⚠ 実行中のジョブがありません。企画 LLM の応答待ちの場合は、応答後に操作できます。</div>');
    return;
  }
  const id = curJobId;
  await cancelJob(id, null);
  addMsg("bot", '<div class="meta">キャンセルしました。</div>');
}

// ---- 動画の続き / アップスケール / 結合 ---------------------------------

function encArg(s) {
  // onclick 属性内の JS 文字列に安全に埋め込むためのエンコード。
  // encodeURIComponent は ' を残すので %27 に畳む（属性の引用符は &quot;
  // 経由で二重引用符になるが、' も畳んでおく方が安全）。
  return encodeURIComponent(s).replace(/'/g, "%27");
}

function videoActionsHtml(fn) {
  // 動画完成メッセージに出すボタン群。ファイル名はエンコードして inline の
  // onclick に載せる（セッション復元 = innerHTML シリアライズ後も動くように）。
  // 属性内の JS 文字列引用符は &quot;（HTML エンティティ）で渡す — このテン
  // プレートは Python の通常文字列なのでバックスラッシュは使えない。
  let html = '<div class="row">' +
    '<button class="ok" onclick="extendVideo(decodeURIComponent(&quot;' + encArg(fn) + '&quot;))">▶ この動画の続きを作る</button>' +
    '<button class="rev" onclick="upscaleVideo(decodeURIComponent(&quot;' + encArg(fn) + '&quot;))">🔍 アップスケール（2倍）</button>' +
    "</div>";
  if (segmentChain.length >= 2 && segmentChain[segmentChain.length - 1] === fn) {
    html += '<div class="row"><button class="ok" onclick="concatVideos(decodeURIComponent(&quot;' +
      encArg(JSON.stringify(segmentChain)) + '&quot;))">🔗 ' + segmentChain.length + "本の動画を1本に結合</button></div>";
  }
  return html;
}

async function extendVideo(fn) {
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了してから続けてください。</div>');
    return;
  }
  const bot = addMsg("bot", '<div class="meta">動画の続きを準備中…（最後の1コマを抜き出しています）</div>');
  try {
    const r = await fetch("/api/extend", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({filename: fn})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    // 最後の1コマを「次の動画の1フレーム目」(I2V) としてセットし、
    // 続きの内容を企画 LLM と相談する（企画モード ON・画像の使い方=先頭固定）。
    refImages = [j.image];
    updateRefSel();
    $("#imguse").value = "first";
    $("#planmode").checked = true;
    $("#btn-reset").style.display = "inline-block";
    planStage = "video";
    extendFrom = fn;
    if (!segmentChain.length || segmentChain[segmentChain.length - 1] !== fn) segmentChain = [fn];
    bot.innerHTML = '<div class="meta">続きの準備 ✅ 最後の1コマをセットしました</div>' +
      "この動画の最後の1コマが「次の動画の1フレーム目」に固定されます。<br>" +
      "次に何が起きますか？（例：「そのままカメラが引いて、彼女が振り返る」）<br>" +
      "内容を話すと企画 LLM がまとめます。OK なら「まとめて」→ 生成で、前作から自然に続く動画になります。";
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
  }
}

async function upscaleVideo(fn) {
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了してから実行してください。</div>');
    return;
  }
  const bot = addMsg("bot", '<div class="meta">アップスケール中…（解像度2倍・数分かかります）</div>');
  try {
    const r = await fetch("/api/upscale", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({filename: fn, scale: 2})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    jobCancelled = false;
    setBusy(true);
    poll(j.prompt_id, bot, "upscale");
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
  }
}

async function concatVideos(encodedJson) {
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了してから実行してください。</div>');
    return;
  }
  let files = [];
  try { files = JSON.parse(encodedJson); } catch (e) {}
  if (!Array.isArray(files) || files.length < 2) {
    addMsg("bot", '<div class="meta">⚠ 結合する動画が不足しています。</div>');
    return;
  }
  const bot = addMsg("bot", '<div class="meta">動画を結合中…（' + files.length + "本 → 1本）</div>");
  try {
    const r = await fetch("/api/concat", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({files: files})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    bot.innerHTML = '<div class="meta">結合完了 ✅（' + files.length + "本 → 1本）</div>" +
      '<video controls autoplay loop muted src="/api/view?filename=' + encodeURIComponent(j.filename) + '&type=output"></video>' +
      '<div class="path">' + esc(j.path) + "</div>";
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
  }
}

function startShutdown() {
  // 生成完了後の停止は「選択式」: 自動カウントダウンで勝手に落とさない。
  // 続きの動画や別の参照画像で連続制作したいケースが多いため、ユーザーが
  // ボタンを選ぶまで ComfyUI / 企画 LLM は生かしたままにする。
  const box = $("#shutdown-box");
  box.style.display = "block";
  box.innerHTML =
    '<div class="meta">生成完了 ✅ このまま続けて生成できます（ComfyUI は起動中）。</div>' +
    '<button onclick="hideShutdown()">▶ 続けて使う</button>' +
    '<button class="warn" onclick="stopAll()">🛑 すべて終了</button>' +
    '<button onclick="stopComfy()">ComfyUI だけ停止</button>';
}

function cancelStop() {
  clearInterval(shutdownTimer);
  shutdownTimer = null;
  $("#shutdown-box").style.display = "none";
  fetch("/api/shutdown", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({scope: "cancel"})
  });
  addMsg("bot", '<div class="meta">停止をキャンセルしました。このまま動画を作り続けられます。</div>');
}

function stopAll() { doShutdown("all"); }
function stopComfy() { doShutdown("comfy"); }

async function doShutdown(scope) {
  clearInterval(shutdownTimer);
  shutdownTimer = null;
  const box = $("#shutdown-box");
  box.innerHTML = '<div class="meta">停止中…（モデルをアンロードして GPU・メモリを解放します）</div>';
  try {
    const r = await fetch("/api/shutdown", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({scope: scope})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    if (scope === "all") {
      box.innerHTML = '<div class="meta">すべて停止しました ✅ GPU・メモリ解放済み。ブラウザは閉じてもらって OK です（動画はファイルとして保存済み）。</div>';
    } else {
      box.innerHTML = '<div class="meta">ComfyUI を停止しました ✅（GPU・VRAM 解放）。動画はこのまま閲覧できます。企画 LLM も止める場合は下のボタンへ。</div>' +
        '<button class="warn" onclick="stopAll()">すべて終了（企画 LLM も停止）</button>' +
        '<button class="small" onclick="hideShutdown()">閉じる</button>';
    }
  } catch (e) {
    box.innerHTML = '<div class="meta">停止エラー: ' + esc(String(e.message || e)) + "</div>";
  }
}

function hideShutdown() { $("#shutdown-box").style.display = "none"; }

// ---- セッション履歴（サイドバー） -------------------------------------
// チャット画面（メッセージ HTML）+ UI 状態をサーバーに JSON 保存し、
// サイドバーに一覧表示して切り替えられる（ChatGPT の履歴と同じ使い勝手）。
// 切り替え時は企画 LLM の会話履歴もサーバー側で一緒に切り替わるので、
// 過去の企画の続きをそのまま相談できる。

function messagesSnapshot() {
  return Array.from($("#msgs").children).map(c => ({
    who: (c.className || "").indexOf("user") >= 0 ? "user" : "bot",
    html: c.innerHTML
  }));
}

function uiSnapshot() {
  return {
    planStage, lastFinalPrompt, lastImgPrompt,
    refImages, refConsultActive,
    imguse: $("#imguse").value,
    curJobId: curJobId, curJobKind: curJobKind,
    segmentChain: segmentChain, extendFrom: extendFrom,
    pinnedChar: pinnedChar
  };
}

// ---- キャラ固定 ---------------------------------------------------------
// config/characters/ を h3-chat サーバーの /api/characters 経由で読み、
// セレクタに並べる。編集は Web GUI (コンフィ側) が担当。選択はサーバーに
// char_id として送り、認知（企画への前置き）と保証（negative/LoRA/seed の
// 機械適用）の両方で使われる。
async function loadCharacters() {
  const sel = $("#char-pin");
  if (!sel) return;
  try {
    const r = await fetch("/api/characters");
    const j = await r.json();
    charLib = j.characters || [];
  } catch (e) { charLib = []; }
  const cur = pinnedChar;
  sel.innerHTML = '<option value="">なし（毎回自由に決める）</option>' +
    charLib.map(c => '<option value="' + esc(c.id) + '">' + esc(c.name || c.id) + '</option>').join("");
  sel.value = charLib.some(c => c.id === cur) ? cur : "";
  pinnedChar = sel.value;
  updateCharPinStatus();
}

function onCharPinChange() {
  pinnedChar = $("#char-pin").value || "";
  updateCharPinStatus();
  saveSession();
}

function updateCharPinStatus() {
  const el = $("#char-pin-status");
  if (!el) return;
  const c = charLib.find(x => x.id === pinnedChar);
  if (!c) { el.textContent = ""; return; }
  const bits = [];
  if (c.seed != null) bits.push("seed " + c.seed);
  const lor = (c.lora && Object.values(c.lora) || []).flat();
  if (lor.length) bits.push("LoRA " + lor.length + "本");
  if ((c.refImages || []).length) bits.push("基準画像 " + c.refImages.length + "枚");
  el.textContent = "📌 " + (bits.length ? bits.join("・") + " で固定中" : "固定中（次のキー画像から）");
}

function charPinSpec() {
  // ピンなしのときはキー自体を送らない（旧サーバー / 従来のリクエスト body
  // と完全に同一になるゼロ影響設計）。
  return pinnedChar ? {char_id: pinnedChar} : {};
}

async function saveSession() {
  const msgs = messagesSnapshot();
  if (!msgs.length && !activeSessionId) return;   // 空の新規チャットは保存しない
  const body = JSON.stringify({id: activeSessionId, messages: msgs, ui: uiSnapshot()});
  if (body === lastSavedJson) return;             // 前回保存から変化なし
  try {
    const r = await fetch("/api/sessions/save", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: body
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    lastSavedJson = body;
    if (j.id) activeSessionId = j.id;
    refreshSidebar();
  } catch (e) {}
}
setInterval(saveSession, 6000);
window.addEventListener("beforeunload", () => {
  // タブを閉じるとき直近の状態を送る（fetch は間に合わないので sendBeacon）
  try {
    const msgs = messagesSnapshot();
    if (!msgs.length && !activeSessionId) return;
    const body = JSON.stringify({id: activeSessionId, messages: msgs, ui: uiSnapshot()});
    if (body !== lastSavedJson && navigator.sendBeacon) {
      navigator.sendBeacon("/api/sessions/save", new Blob([body], {type: "application/json"}));
    }
  } catch (e) {}
});

function relTime(ts) {
  const d = Math.floor(Date.now() / 1000 - (ts || 0));
  if (d < 60) return "たった今";
  if (d < 3600) return Math.floor(d / 60) + " 分前";
  if (d < 86400) return Math.floor(d / 3600) + " 時間前";
  return Math.floor(d / 86400) + " 日前";
}

async function refreshSidebar() {
  try {
    const r = await fetch("/api/sessions");
    const j = await r.json();
    if (!r.ok) return;
    const list = $("#sess-list");
    list.innerHTML = "";
    const sessions = j.sessions || [];
    if (!sessions.length) {
      const d = document.createElement("div");
      d.id = "sess-empty";
      d.textContent = "まだ履歴がありません。始めた企画がここに自動で表示されます。";
      list.appendChild(d);
      return;
    }
    sessions.forEach(s => {
      const d = document.createElement("div");
      d.className = "sessitem" + (s.id === activeSessionId ? " active" : "");
      const t = document.createElement("div");
      t.className = "sesstitle";
      t.textContent = s.title || "新しい企画";
      const tm = document.createElement("div");
      tm.className = "sesstime";
      tm.textContent = relTime(s.updated) + "・" + (s.n || 0) + " メッセージ";
      const del = document.createElement("button");
      del.className = "sessdel";
      del.textContent = "🗑";
      del.title = "この企画を削除";
      del.onclick = (e) => { e.stopPropagation(); deleteSession(s.id); };
      d.appendChild(t);
      d.appendChild(tm);
      d.appendChild(del);
      d.onclick = () => switchSession(s.id);
      list.appendChild(d);
    });
  } catch (e) {}
}

async function switchSession(id) {
  if (busy) {
    alert("生成が進行中です。完了してから切り替えてください（✕ キャンセルで中止できます）。");
    return;
  }
  if (id && id === activeSessionId) return;
  await saveSession();   // 今表示中の画面を先に確定保存する
  try {
    const r = await fetch("/api/sessions/switch", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({id: id || null})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    renderSession(j.session);
  } catch (e) {
    alert("セッションを切り替えられませんでした: " + (e.message || e));
  }
}

function renderSession(doc) {
  // 切り替え前の画面のポーリングを止める
  jobCancelled = true;
  curJobId = null;
  curJobKind = null;
  // ローカル状態をリセット
  lastImgPrompt = null;
  lastFinalPrompt = null;
  planStage = "chat";
  refConsultActive = false;
  refImages = [];
  refPickerSelection = [];
  segmentChain = [];
  extendFrom = null;
  if (shutdownTimer) { clearInterval(shutdownTimer); shutdownTimer = null; }
  hideShutdown();
  $("#msgs").innerHTML = "";
  lastSavedJson = "";
  if (!doc) {
    activeSessionId = null;
    updateRefSel();
    refreshSidebar();
    return;
  }
  activeSessionId = doc.id;
  const ui = doc.ui || {};
  planStage = ui.planStage || "chat";
  lastFinalPrompt = ui.lastFinalPrompt || null;
  lastImgPrompt = ui.lastImgPrompt || null;
  refImages = Array.isArray(ui.refImages) ? ui.refImages : [];
  refConsultActive = !!ui.refConsultActive;
  segmentChain = Array.isArray(ui.segmentChain) ? ui.segmentChain.filter(x => typeof x === "string") : [];
  extendFrom = typeof ui.extendFrom === "string" ? ui.extendFrom : null;
  if (ui.imguse === "first" || ui.imguse === "last" || ui.imguse === "ref") $("#imguse").value = ui.imguse;
  pinnedChar = typeof ui.pinnedChar === "string" ? ui.pinnedChar : "";
  loadCharacters();
  updateRefSel();
  const clr = $("#ref-clear");
  if (clr) clr.style.display = refImages.length ? "inline-block" : "none";
  (doc.messages || []).forEach(m => addMsg(m.who, m.html));
  $("#msgs").scrollTop = $("#msgs").scrollHeight;
  // 保存時に未完了だった生成ジョブがあればポーリングを再開する
  if (ui.curJobId) {
    const kids = $("#msgs").children;
    let lastBot = null;
    for (let i = kids.length - 1; i >= 0; i--) {
      if ((kids[i].className || "").indexOf("bot") >= 0) { lastBot = kids[i]; break; }
    }
    if (lastBot) {
      curJobId = ui.curJobId;
      curJobKind = (ui.curJobKind === "image" || ui.curJobKind === "upscale") ? ui.curJobKind : "video";
      setBusy(true);
      if (curJobKind === "image") pollImage(ui.curJobId, lastBot);
      else poll(ui.curJobId, lastBot, curJobKind);
    }
  }
  refreshSidebar();
}

async function newChat() {
  if (busy) {
    alert("生成が進行中です。完了してから新しい企画を始めてください（✕ キャンセルで中止できます）。");
    return;
  }
  await saveSession();
  try {
    const r = await fetch("/api/sessions/switch", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({id: null})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    renderSession(null);
  } catch (e) {
    alert("新しい企画を始められませんでした: " + (e.message || e));
  }
}

async function deleteSession(id) {
  if (id === activeSessionId) {
    alert("今表示中のセッションは削除できません。先に他に切り替えてください。");
    return;
  }
  if (!confirm("この企画を履歴から削除しますか？")) return;
  try {
    const r = await fetch("/api/sessions/delete", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({id: id})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    refreshSidebar();
  } catch (e) {
    alert("削除できませんでした: " + (e.message || e));
  }
}

function toggleSidebar() {
  $("#sidebar").classList.toggle("hidden");
}

// ページ読み込み時: 最後に表示していたセッションを復元しサイドバーを描画する。
async function initSessions() {
  try {
    const r = await fetch("/api/sessions");
    const j = await r.json();
    if (!r.ok) return;
    if (j.active) renderSession(j.active);
    else refreshSidebar();
  } catch (e) {}
}
initSessions();
loadCharacters();

async function resetPlan() {
  // 進行中の生成ジョブがあれば先にキャンセルする
  if (curJobId) {
    try {
      await fetch("/api/cancel", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({prompt_id: curJobId})
      });
    } catch (e) {}
  }
  jobCancelled = true;
  curJobId = null;
  curJobKind = null;
  setBusy(false);
  // 自動停止カウントダウンが残っていれば解除する
  if (shutdownTimer) { clearInterval(shutdownTimer); shutdownTimer = null; }
  $("#shutdown-box").style.display = "none";
  // 今の企画を履歴に保存してから、サーバー側で新しいセッション始める。
  // 以前は fire-and-forget の __RESET__ で、失敗しても気づかずサーバーに
  // 古い企画状態が残ったまま次の企画が始まっていた。
  try {
    await saveSession();
    const r = await fetch("/api/sessions/switch", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({id: null})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
  } catch (e) {
    addMsg("bot", '<div class="meta">⚠ サーバー側のリセットに失敗しました（' + esc(String(e.message || e)) + '）。企画 LLM に古い会話が残っている可能性があります。もう一度「🔄 新しい企画」を押してください。</div>');
    return;
  }
  renderSession(null);
}

$("#planmode").addEventListener("change", e => {
  $("#btn-reset").style.display = e.target.checked ? "inline-block" : "none";
});

$("#input").addEventListener("keydown", e => {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); }
});
</script>
</body>
</html>
"""


__all__ = ['HERE', 'REPO', 'HTML']
