import json
import os
import sqlite3
import sys
import time


def ensure_llamadock_model_defaults() -> None:
    """Register conservative defaults for the local 1Q model in Open WebUI.

    Open WebUI's chat controls otherwise send its generic temperature/output
    defaults.  A workspace-model override lets the normal chat UI inherit
    settings that are appropriate for this local quantized runtime while
    leaving the user free to override them in Controls.
    """

    model_id = os.environ.get("LLAMADOCK_OPEN_WEBUI_SAFE_MODEL_ID", "").strip()
    data_dir = os.environ.get("DATA_DIR", "").strip()
    if not model_id or not data_dir:
        return

    db_path = os.path.join(data_dir, "webui.db")
    if not os.path.exists(db_path):
        return

    params = {
        "temperature": 0.0,
        "max_tokens": 512,
        "top_p": 1.0,
        "min_p": 0.05,
        "seed": 42,
        # Do not persist `stream: true` in the model override.  Open WebUI's
        # web-search query generator explicitly sends `stream: false`, but
        # model overrides are applied afterwards.  Persisting stream=true
        # therefore turns the internal query-generation call into an SSE
        # response, while the search middleware expects a JSON object.  The
        # normal chat composer supplies stream=true itself, so removing this
        # override keeps ordinary streaming and restores search compatibility.
        # The local 1Q profile prioritizes usable answers over hidden chain of
        # thought.  Without this, Gemma-style reasoning can consume the full
        # 512-token cap and leave Open WebUI with an empty visible answer.
        "chat_template_kwargs": {"enable_thinking": False},
        # Keep ordinary local chats on Open WebUI's legacy path.  The native
        # path injects every built-in personal tool into each request, which
        # needlessly expands the prompt and is especially costly for 1Q.
        # Web search remains available through Open WebUI's legacy search
        # handler when the user enables the Web Search control.
        "function_calling": "legacy",
    }
    marker = "llamadock_safe_defaults_v2"
    meta = {
        "description": "LlamaDock local 1Q model defaults: deterministic, bounded output, client-selected streaming.",
        "llamadock_managed": marker,
    }
    rag_template = """### Task:
Respond to the user query using the provided context.

### Guidelines:
- Respond in the same language as the user's query.
- If the user asks for URLs or sources, copy at least one exact `Source URL:` value from the context into the answer. It must begin with `http://` or `https://`.
- Never claim that the context lacks an explicit URL when a `Source URL:` line is present.
- Do not invent URLs. If no `Source URL:` is present, state that no URL was available.
- If you don't know the answer, clearly state that.

<context>
{{CONTEXT}}
</context>
"""

    try:
        con = sqlite3.connect(db_path, timeout=5)
        con.execute("PRAGMA busy_timeout=5000")

        # Open WebUI persists OpenAI-compatible endpoints in its database.
        # Environment variables alone do not replace an older 8080 entry, so
        # a relaunch could silently bypass the LlamaDock recovery gateway.
        api_base_url = os.environ.get("OPENAI_API_BASE_URLS", "").strip()
        if api_base_url:
            encoded = json.dumps([api_base_url])
            if con.execute("SELECT 1 FROM config WHERE key = ?", ("openai.api_base_urls",)).fetchone():
                con.execute("UPDATE config SET value = ? WHERE key = ?", (encoded, "openai.api_base_urls"))
            else:
                con.execute("INSERT INTO config (key, value) VALUES (?, ?)", ("openai.api_base_urls", encoded))
            print(f"Open WebUI: OpenAI-compatible endpoint set to {api_base_url}")

        # These cosmetic jobs use the same local inference slot as the chat.
        # On a new conversation Open WebUI otherwise starts title, tags and
        # follow-up generations in addition to the user-visible answer.  The
        # launcher keeps them off by default; -EnableBackgroundTasks opts in.
        if os.environ.get("LLAMADOCK_OPEN_WEBUI_BACKGROUND_TASKS", "False").lower() not in {"1", "true", "yes", "on"}:
            for key in (
                "task.title.enable",
                "task.tags.enable",
                "task.follow_up.enable",
            ):
                encoded = json.dumps(False)
                if con.execute("SELECT 1 FROM config WHERE key = ?", (key,)).fetchone():
                    con.execute("UPDATE config SET value = ? WHERE key = ?", (encoded, key))
                else:
                    con.execute("INSERT INTO config (key, value) VALUES (?, ?)", (key, encoded))
            print("Open WebUI: disabled cosmetic background generations for local speed")

        # The local launcher does not provision an embedding service.  Keep
        # web search enabled, but pass the fetched search documents directly
        # to the chat instead of sending them through an unavailable vector
        # retrieval stage.  The runtime middleware also prefixes each web
        # document with its canonical URL so the model can print real URLs,
        # not only the clickable source cards shown by the UI.
        key = "web.search.bypass_embedding_and_retrieval"
        encoded = json.dumps(True)
        if con.execute("SELECT 1 FROM config WHERE key = ?", (key,)).fetchone():
            con.execute("UPDATE config SET value = ? WHERE key = ?", (encoded, key))
        else:
            con.execute("INSERT INTO config (key, value) VALUES (?, ?)", (key, encoded))
        print("Open WebUI: web search uses direct fetched context (no local embeddings required)")

        key = "web.search.bypass_web_loader"
        encoded = json.dumps(True)
        if con.execute("SELECT 1 FROM config WHERE key = ?", (key,)).fetchone():
            con.execute("UPDATE config SET value = ? WHERE key = ?", (encoded, key))
        else:
            con.execute("INSERT INTO config (key, value) VALUES (?, ?)", (key, encoded))
        print("Open WebUI: web search uses provider snippets (page loader bypassed for context safety)")

        # Keep fetched web context below the 32k local context limit even when
        # an older Open WebUI database already contains larger values.
        for key, value in {
            "web.search.result_count": 3,
            "web.fetch.max_content_length": 6000,
            "rag.template": rag_template,
        }.items():
            encoded = json.dumps(value)
            if con.execute("SELECT 1 FROM config WHERE key = ?", (key,)).fetchone():
                con.execute("UPDATE config SET value = ? WHERE key = ?", (encoded, key))
            else:
                con.execute("INSERT INTO config (key, value) VALUES (?, ?)", (key, encoded))
        print("Open WebUI: limited web context to 3 results and 6000 characters per page")

        user_row = con.execute(
            "SELECT id FROM user WHERE role = 'admin' ORDER BY created_at LIMIT 1"
        ).fetchone()
        if not user_row:
            con.close()
            return

        row = con.execute(
            "SELECT user_id, base_model_id, name, params, meta, is_active FROM model WHERE id = ?",
            (model_id,),
        ).fetchone()
        now = int(time.time())
        if row is None:
            con.execute(
                """
                INSERT INTO model
                    (id, user_id, base_model_id, name, params, meta, updated_at, created_at, is_active)
                VALUES (?, ?, NULL, ?, ?, ?, ?, ?, 1)
                """,
                (
                    model_id,
                    user_row[0],
                    model_id,
                    json.dumps(params),
                    json.dumps(meta),
                    now,
                    now,
                ),
            )
            con.commit()
            print(f"Open WebUI: registered safe local model defaults for {model_id}")
        else:
            existing_meta = json.loads(row[4] or "{}")
            if existing_meta.get("llamadock_managed") in {"llamadock_safe_defaults_v1", marker}:
                con.execute(
                    "UPDATE model SET params = ?, meta = ?, updated_at = ?, is_active = 1 WHERE id = ?",
                    (json.dumps(params), json.dumps(meta), now, model_id),
                )
                con.commit()
                print(f"Open WebUI: refreshed safe local model defaults for {model_id}")
            else:
                print(f"Open WebUI: kept existing custom model settings for {model_id}")
        con.close()
    except (OSError, sqlite3.Error, ValueError) as exc:
        print(f"WARNING: could not register Open WebUI model defaults: {exc}")

site_dir = os.environ.get("LLAMADOCK_OPEN_WEBUI_SITE")
if site_dir and site_dir not in sys.path:
    sys.path.insert(0, site_dir)

ensure_llamadock_model_defaults()

from open_webui import app


if __name__ == "__main__":
    app()
