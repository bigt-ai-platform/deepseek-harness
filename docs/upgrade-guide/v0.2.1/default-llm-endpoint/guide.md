---
kind: upgrade-guide
description: "The shipped DeepSeek endpoint defaults to the llm.bigt.ai gateway instead of the public API."
---

# Default DeepSeek endpoint is the llm.bigt.ai gateway

English | [中文](guide.zh.md)

## Change

The base bundle previously left the Messages endpoint unset, so it resolved to the public DeepSeek API unless the launch environment or the `llm-deepseek:` settings section supplied one. The bundled entry now sets `baseURL: https://llm.bigt.ai/api`, this fork's gateway endpoint, which serves the DeepSeek V4 Flash family through its provider failover chain.

Affected are installations that relied on the public default or on `DEEPSEEK_BASE_URL` alone. The settings section still overrides the entry, so a user-set or saved endpoint keeps working, but `DEEPSEEK_BASE_URL` no longer selects the endpoint: an explicit entry value outranks the launch environment. The gateway serves Messages only, so attachment offload to the Files API (`/v1/files`) fails there; images within the inline budget still work.

## Migration

1. To keep the public API, set the endpoint in the `llm-deepseek:` settings section (Desktop and Web: Settings → Models), for example `baseURL: https://api.deepseek.com/anthropic`, which outranks the bundled entry.
2. To use the gateway, store a gateway-issued key (`dap_...`) as the `DEEPSEEK_API_KEY` credential in the same settings page; public DeepSeek keys are rejected there.
3. Confirm the choice with one task: `dsh --profile headless "Reply with exactly: pong"` prints `pong` for the configured endpoint, and an authentication failure names the endpoint that answered.
