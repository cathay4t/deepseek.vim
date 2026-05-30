#!/usr/bin/env python3
"""DeepSeek Vim Agent - HTTP client for DeepSeek API.

Reads JSON-RPC style requests from stdin (one JSON object per line),
makes HTTP calls to DeepSeek API, and writes responses to stdout.

Protocol:
  Request:  {"id": N, "method": "init"|"complete"|"fim", "params": {...}}
  Response: {"id": N, "result": {...}} or {"id": N, "error": {...}}
"""

import json
import os
import sys
import urllib.error
import urllib.request


BETA_BASE_URL = "https://api.deepseek.com/beta"


def handle_complete(params, api_key):
    prompt = params.get("prompt", "")
    suffix = params.get("suffix", "")
    model = params.get("model", "deepseek-v4-flash")
    max_tokens = params.get("max_tokens", 256)
    temperature = params.get("temperature", 0)

    context = prompt + "‹CURSOR›" + suffix

    messages = [
        {
            "role": "system",
            "content": (
                "You are a code completion engine. Given code with a ‹CURSOR› "
                "marker, return ONLY what should replace the ‹CURSOR› marker. "
                "No explanations, no markdown formatting."
            ),
        },
        {
            "role": "user",
            "content": "```\n" + context + "\n```",
        },
    ]

    body = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "thinking": {"type": "disabled"},
        "stream": False,
    }

    result = _make_request(
        f"{BETA_BASE_URL}/chat/completions", body, api_key
    )
    if "error" not in result:
        content = result["choices"][0]["message"]["content"]
        return {
            "text": content,
            "finish_reason": result["choices"][0].get("finish_reason", "stop"),
        }
    return result


def handle_fim(params, api_key):
    prompt = params.get("prompt", "")
    suffix = params.get("suffix", "")
    max_tokens = params.get("max_tokens", 256)
    temperature = params.get("temperature", 0)

    body = {
        "model": "deepseek-v4-pro",
        "prompt": prompt,
        "suffix": suffix,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": False,
    }

    result = _make_request(f"{BETA_BASE_URL}/completions", body, api_key)
    if "error" not in result:
        return {
            "text": result["choices"][0]["text"],
            "finish_reason": result["choices"][0].get("finish_reason", "stop"),
        }
    return result


def _make_request(url, body, api_key):
    if not api_key:
        return {"error": "API key not configured. Set g:deepseek_api_key or DEEPSEEK_VIM_API_KEY env"}

    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8", errors="replace")
        return {"error": f"HTTP {e.code}: {error_body}"}
    except Exception as e:
        return {"error": str(e)}


def main():
    api_key = os.environ.get("DEEPSEEK_VIM_API_KEY", "")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except json.JSONDecodeError as e:
            sys.stdout.write(
                json.dumps({"id": 0, "error": {"message": f"JSON parse error: {e}"}})
                + "\n"
            )
            sys.stdout.flush()
            continue

        req_id = request.get("id", 0)
        method = request.get("method", "")
        params = request.get("params", {})

        try:
            if method == "init":
                if "api_key" in params and params["api_key"]:
                    api_key = params["api_key"]
                response = {"id": req_id, "result": {"status": "ok"}}
            elif method == "complete":
                result = handle_complete(params, api_key)
                if "error" in result:
                    response = {"id": req_id, "error": result}
                else:
                    response = {"id": req_id, "result": result}
            elif method == "fim":
                result = handle_fim(params, api_key)
                if "error" in result:
                    response = {"id": req_id, "error": result}
                else:
                    response = {"id": req_id, "result": result}
            else:
                response = {
                    "id": req_id,
                    "error": {"message": f"Unknown method: {method}"},
                }
        except Exception as e:
            response = {"id": req_id, "error": {"message": str(e)}}

        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
