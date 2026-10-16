---
kind: upgrade-guide
description: "随发行版提供的 DeepSeek 端点默认改为 llm.bigt.ai 网关，而非公共 API。"
---

# DeepSeek 默认端点改为 llm.bigt.ai 网关

[English](guide.md) | 中文

## 变更

此前基础 bundle 未设置 Messages 端点，因此除非启动环境或 `llm-deepseek:` 设置节提供端点，否则会解析到 DeepSeek 公共 API。现在 bundle 条目设置了 `baseURL: https://llm.bigt.ai/api`，即本 fork 的网关端点，它通过供应商故障转移链服务 DeepSeek V4 Flash 系列。

受影响的是仅依赖公共默认值或仅依赖 `DEEPSEEK_BASE_URL` 的安装。设置节仍会覆盖该条目，因此用户设置或已保存的端点继续生效；但 `DEEPSEEK_BASE_URL` 不再能选择端点：条目中的显式值优先于启动环境。网关只提供 Messages，因此附件转存到 Files API（`/v1/files`）会失败；内联预算内的图片仍可使用。

## 迁移

1. 若要继续使用公共 API，请在 `llm-deepseek:` 设置节中设置端点（桌面端与 Web：Settings → Models），例如 `baseURL: https://api.deepseek.com/anthropic`，其优先级高于 bundle 条目。
2. 若要使用网关，请在同一设置页把网关签发的密钥（`dap_...`）保存为 `DEEPSEEK_API_KEY` 凭据；公共 DeepSeek 密钥会被网关拒绝。
3. 用一个任务确认选择：`dsh --profile headless "Reply with exactly: pong"` 对已配置端点会输出 `pong`，认证失败时错误会指明做出应答的端点。
