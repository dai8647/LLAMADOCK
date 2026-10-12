# W23 - auto-compaction fallback in tools/llamadock-proxy.mjs

Commit `88ae351` (that one file only). 8080/strata.exe was never touched; only the 8090 gateway was restarted, with its original command line.

## Location
- **Section lines 239-471**, between `// === COMPACTION FALLBACK: ... ===` and `// === END COMPACTION FALLBACK ===`: kill switch, refusal matcher, estimator, elision helper, entry point `maybeCompactForContext()`, hook `applyContextCompactionFallback()`. Nothing outside the section references it.
- **Call site lines 604-614** (one statement in the request path) plus `const`->`let` on line 598. Fires only on `POST /v1/chat/completions` plus HTTP 400 matching `prompt (N tokens) leaves no room to answer in the context (M)`.

## Tests (via 8090, real Strata 0.1.40, n_ctx 65536) - all PASS
1. **Regression, flag unset** - 2-message chat -> `200`, real completion `"pong"` (28 prompt tokens).
2. **Regression, `LLAMADOCK_COMPACTION=0`** (gateway restarted with the var) -> `200`, `"pong"`.
3. **Oversized, flag unset** - one 450 016-char user message = **82 668 prompt tokens** -> 400 -> compaction -> single retry -> `200` with a real completion. Log: `compaction: prompt 82668 > ctx 65536; kept system + newest 0 of 0 messages, est ~1014 tokens; retrying once`.
4. **Oversized, `LLAMADOCK_COMPACTION=0`** -> `400`, body forwarded unchanged (`{"error":{"type":"invalid_request_error","message":"prompt (82668 tokens) leaves no room to answer in the context (65536); requests are never truncated"}}`), no compaction log.
5. **Streaming, flag unset** - same body, `"stream": true` -> `200`, `text/event-stream`, 196 chunks / 46 339 bytes, ends with `data: [DONE]`.
6. Extra: DSH-shaped 305-message history (266 783 tokens) -> `200` (`kept system + newest 58 of 303 messages, est ~64403 tokens; retrying once`); a *different* 400 (`No messages provided.`) is forwarded unchanged and never retried.

## Env flag
`LLAMADOCK_COMPACTION=0` disables the feature completely - the response is not even buffered (default ON; any other value = ON).

## Removal when DSH ships native compaction
Delete lines 239-471, delete lines 604-614, restore `const upstreamResponse` on line 598. Verified mechanically: the result is byte-identical to `git show HEAD~1:tools/llamadock-proxy.mjs` and passes `node --check`.

## Honest caveats
- The brief's regex (`... in the context (\d+)`) does not match the live body - Strata emits `the context (65536)` with parentheses; the shipped pattern makes those parens optional.
- The final user turn is never dropped, but if it alone exceeds the budget it is elided to 2K+2K chars like an oversized tool result; 82 668 tokens verbatim against a 65 536 context could never succeed, so the brief's own oversized test (expect 200) requires this.
- Estimation is JSON chars/4 as specified; it over-counts ~1.35-1.4x versus the engine (est 64 403 vs actual 45 887), so ~30 % less history is kept than possible - safe direction, it cannot cause a second 400.
- Tool messages orphaned by dropping their assistant turn are removed so the chat template never sees an unmatched `<tool_response>`. No summarization is performed.
- Unrelated working-tree edits (`config/params-schema.json`, `select-model.ps1`) were left uncommitted.