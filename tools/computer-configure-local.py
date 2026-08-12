"""Add or update the localhost llama.cpp connection in cptr's config store."""

from __future__ import annotations

import asyncio
import os
import uuid

from cptr.models import Config
from cptr.utils.config import _get_jwt_secret
from cptr.utils.crypto import encrypt_key


BASE_URL = os.environ.get("LLAMADOCK_COMPUTER_BASE_URL", "http://127.0.0.1:8080/v1").rstrip("/")
NAME = os.environ.get("LLAMADOCK_COMPUTER_CONNECTION_NAME", "LlamaDock local")
MANAGED_CHAT_DEFAULTS = "llamadock_managed_chat_defaults_v1"


def merge_chat_defaults(existing: object) -> dict:
    """Apply bounded local-model defaults without removing other cptr settings."""

    models = dict(existing) if isinstance(existing, dict) else {}
    global_entry = dict(models.get("*") or {})
    params = dict(global_entry.get("params") or {})
    request_params = dict(params.get("request_params") or {})
    chat_template_kwargs = dict(request_params.get("chat_template_kwargs") or {})
    chat_template_kwargs["enable_thinking"] = False
    request_params.update(
        {
            "temperature": 0,
            "top_p": 1,
            "min_p": 0.05,
            "seed": 42,
            "max_tokens": 512,
            "chat_template_kwargs": chat_template_kwargs,
        }
    )
    params["request_params"] = request_params
    params["llamadock_managed"] = MANAGED_CHAT_DEFAULTS
    global_entry["params"] = params
    models["*"] = global_entry
    return models


async def main() -> None:
    connections = list(await Config.get("chat.connections") or [])
    connection = next((item for item in connections if item.get("name") == NAME), None)
    if connection is None:
        connection = {"id": str(uuid.uuid4()), "name": NAME}
        connections.append(connection)

    connection.update(
        {
            "provider": "openai",
            "api_type": "chat_completions",
            "provider_type": "llama.cpp",
            "prefix_id": None,
            "base_url": BASE_URL,
            "api_key": encrypt_key("not-needed", _get_jwt_secret()),
            "enabled": True,
            "data": {},
        }
    )
    await Config.upsert({"chat.connections": connections})
    current_models = await Config.get("chat.models")
    await Config.upsert({"chat.models": merge_chat_defaults(current_models)})
    print(
        f"configured={NAME} base_url={BASE_URL} count={len(connections)} "
        f"chat_defaults={MANAGED_CHAT_DEFAULTS}"
    )


if __name__ == "__main__":
    asyncio.run(main())
