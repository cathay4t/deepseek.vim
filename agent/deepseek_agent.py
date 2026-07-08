#!/usr/bin/env python3
"""DeepSeek Vim Agent - HTTP client for DeepSeek API.

Reads JSON-RPC style requests from stdin (one JSON object per line),
makes HTTP calls to DeepSeek API, and writes responses to stdout.

Uses persistent HTTPS connections to avoid TCP/TLS handshake overhead
on every request.

Protocol:
  Request:  {"id": N, "method": "init"|"complete"|"fim", "params": {...}}
  Response: {"id": N, "result": {...}} or {"id": N, "error": {...}}
"""

import http.client
import json
import os
import ssl
import sys
import time

API_HOST = "api.deepseek.com"
API_PATH_COMPLETE = "/beta/chat/completions"
API_PATH_FIM = "/beta/completions"

_conn = None
_ctx = None


def _get_connection():
    global _conn, _ctx
    if _ctx is None:
        _ctx = ssl.create_default_context()
    if _conn is None:
        _conn = http.client.HTTPSConnection(API_HOST, context=_ctx, timeout=30)
    return _conn


def _reset_connection():
    global _conn
    if _conn is not None:
        try:
            _conn.close()
        except Exception:
            pass
        _conn = None


def _make_request(path, body, api_key, retries=1):
    if not api_key:
        return {
            "error": "API key not configured. Set g:deepseek_api_key or DEEPSEEK_VIM_API_KEY env"
        }

    data = json.dumps(body).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Authorization": "Bearer " + api_key,
        "Content-Length": str(len(data)),
    }

    for attempt in range(retries + 1):
        if attempt > 0:
            _reset_connection()
            time.sleep(2**attempt)
        try:
            conn = _get_connection()
            conn.request("POST", path, body=data, headers=headers)
            resp = conn.getresponse()
            resp_body = resp.read().decode("utf-8", errors="replace")
        except (http.client.HTTPException, ConnectionError, OSError) as e:
            _reset_connection()
            if attempt < retries:
                continue
            return {"error": str(e)}

        if resp.status >= 500:
            if attempt < retries:
                continue
            return {"error": "HTTP " + str(resp.status) + ": " + resp_body[:500]}

        if resp.status == 429:
            if attempt < retries:
                time.sleep(5)
                continue
            return {"error": "HTTP 429 (Rate limited): " + resp_body[:500]}

        if resp.status >= 400:
            _reset_connection()
            return {"error": "HTTP " + str(resp.status) + ": " + resp_body[:500]}

        try:
            return json.loads(resp_body)
        except json.JSONDecodeError:
            return {"error": "Invalid JSON response: " + resp_body[:500]}


def _extract_chat_completion(result):
    if "choices" not in result or not result["choices"]:
        return {"error": "Unexpected API response: missing choices"}
    choice = result["choices"][0]
    if "message" not in choice or "content" not in choice["message"]:
        return {"error": "Unexpected API response: missing message.content"}
    return None


def handle_complete(params, api_key):
    prompt = params.get("prompt", "")
    suffix = params.get("suffix", "")
    model = params.get("model", "deepseek-v4-flash")
    max_tokens = params.get("max_tokens", 256)
    temperature = params.get("temperature", 0)

    context = prompt + "\u2039CURSOR\u203a" + suffix

    messages = [
        {
            "role": "system",
            "content": (
                "You are a code completion engine. Given code with a \u2039CURSOR\u203a "
                "marker, return ONLY what should replace the \u2039CURSOR\u203a marker. "
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

    result = _make_request(API_PATH_COMPLETE, body, api_key)
    if "error" in result:
        return result
    validate_error = _extract_chat_completion(result)
    if validate_error is not None:
        return validate_error
    content = result["choices"][0]["message"]["content"]
    return {
        "text": content,
        "finish_reason": result["choices"][0].get("finish_reason", "stop"),
    }


def _extract_text_completion(result):
    if "choices" not in result or not result["choices"]:
        return {"error": "Unexpected API response: missing choices"}
    choice = result["choices"][0]
    if "text" not in choice:
        return {"error": "Unexpected API response: missing text"}
    return None


def handle_fim(params, api_key):
    prompt = params.get("prompt", "")
    suffix = params.get("suffix", "")
    model = params.get("model", "deepseek-v4-pro")
    max_tokens = params.get("max_tokens", 256)
    temperature = params.get("temperature", 0)

    body = {
        "model": model,
        "prompt": prompt,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": False,
    }
    if suffix:
        body["suffix"] = suffix

    result = _make_request(API_PATH_FIM, body, api_key)
    if "error" in result:
        return result
    validate_error = _extract_text_completion(result)
    if validate_error is not None:
        return validate_error
    return {
        "text": result["choices"][0]["text"],
        "finish_reason": result["choices"][0].get("finish_reason", "stop"),
    }


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
                json.dumps(
                    {"id": 0, "error": {"message": "JSON parse error: " + str(e)}}
                )
                + "\n"
            )
            sys.stdout.flush()
            continue

        req_id = request.get("id", 0)
        method = request.get("method", "")
        params = request.get("params", {})

        response = {"id": req_id}

        try:
            if method == "init":
                if "api_key" in params:
                    api_key = params["api_key"] or ""
                response["result"] = {"status": "ok"}
            elif method == "complete":
                result = handle_complete(params, api_key)
                if "error" in result:
                    response["error"] = result
                else:
                    response["result"] = result
            elif method == "fim":
                result = handle_fim(params, api_key)
                if "error" in result:
                    response["error"] = result
                else:
                    response["result"] = result
            else:
                response["error"] = {"message": "Unknown method: " + method}
        except (KeyError, IndexError, TypeError, ValueError) as e:
            response["error"] = {"message": "Unexpected response: " + str(e)}

        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
