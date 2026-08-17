"""Unit tests for h3-chat.py tag extraction (run from repo root)."""
import importlib.util

spec = importlib.util.spec_from_file_location("h3chat", "tools/h3-chat.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

passed = failed = 0

def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}  {detail}")

# --- Case 1: normal bracket pair -------------------------------------------
t1 = "了解です。\n[IMG_PROMPT]A cat on a windowsill, golden hour, photorealistic[/IMG_PROMPT]\n以上です。"
r1 = m._best_tag_match(m.IMG_FINAL_RE, t1)
check("bracket pair IMG_PROMPT", r1 == "A cat on a windowsill, golden hour, photorealistic", repr(r1))

# --- Case 2: XML-style closer </TAG> (the live-test bug) --------------------
t2 = ("動画プロンプトです。\n[FINAL_PROMPT]\nA woman sips a drink, camera dollies in.\n"
      "overall_soundscape: jazz bar murmur.\nnon_diegetic_music: slow jazz.\n"
      "</FINAL_PROMPT>")
r2 = m._best_tag_match(m.FINAL_RE, t2)
check("XML closer </FINAL_PROMPT>",
      r2 is not None and "dollies in" in r2 and "</FINAL_PROMPT>" not in r2, repr(r2))

t2b = "[IMG_PROMPT]A neon street, rain, cinematic[/IMG_PROMPT]"
t2c = "[IMG_PROMPT]A neon street, rain, cinematic</IMG_PROMPT>"
check("XML closer </IMG_PROMPT>",
      m._best_tag_match(m.IMG_FINAL_RE, t2c) == "A neon street, rain, cinematic",
      repr(m._best_tag_match(m.IMG_FINAL_RE, t2c)))

# --- Case 3: multiple pairs -> longest wins ---------------------------------
t3 = ("下書き: [IMG_PROMPT]draft sketch[/IMG_PROMPT]\n"
      "本番: [IMG_PROMPT]A full detailed scene with lighting, composition, mood, 8k[/IMG_PROMPT]")
r3 = m._best_tag_match(m.IMG_FINAL_RE, t3)
check("longest of multiple pairs", r3 is not None and "full detailed scene" in r3, repr(r3))

# --- Case 4: unclosed tag + English prompt -> recover ------------------------
t4 = "[IMG_PROMPT]A shiba inu running along the shoreline at sunset, warm golden light, low-angle"
r4 = m._unclosed_tag(t4, "IMG_PROMPT")
check("unclosed tag recovery (English)", r4 is not None and "shiba inu" in r4, repr(r4))

# --- Case 5: unclosed tag + Japanese prose -> refuse -------------------------
t5 = "[IMG_PROMPT]\nすみません、もう一度考えさせてください。被写体についてですが、もう少し詳しく教えてもらえますか？"
r5 = m._unclosed_tag(t5, "IMG_PROMPT")
check("unclosed tag refusal (Japanese)", r5 is None, repr(r5))

# --- Case 6: unclosed tag with XML closer line -> stop before it -------------
t6 = "[FINAL_PROMPT]\nA slow dolly-in on the woman's face, shallow depth of field.\n</FINAL_PROMPT>\n補足: 以上です。"
r6 = m._unclosed_tag(t6, "FINAL_PROMPT")
check("unclosed recovery stops at </TAG>",
      r6 is not None and "</FINAL_PROMPT>" not in r6 and "補足" not in r6, repr(r6))

# --- Case 7: Midjourney params stripped --------------------------------------
t7 = "A portrait, 8k --ar 16:9 --style raw --q 2 --v 6.0"
r7 = m._strip_gen_params(t7)
check("strip gen params", r7 == "A portrait, 8k", repr(r7))

# --- Case 8: AUDIO_SET with XML closer ---------------------------------------
t8 = "[AUDIO_SET]\nvoice: soft female\ndialogue: hello\nsfx: rain\nmusic: piano\n</AUDIO_SET>"
r8 = m._best_tag_match(m.AUDIO_SET_RE, t8)
check("AUDIO_SET XML closer", r8 is not None and "soft female" in r8, repr(r8))

print(f"\n{passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
