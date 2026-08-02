# LLM Provider 配置指引（llm_providers.md）

> 对应 `config.json.llm` / `llm_config.json` 的字段（DESIGN-v3.3-llm §3.2 / §4.5）。
> `api_key` 只写 `<state>/llm_config.json`（权限 0600），**绝不**写进 config.json / argv / 日志 / events。

## 通用字段

| 字段 | 说明 |
|---|---|
| `provider` | `deepseek` \| `openai` \| `openrouter` \| `openai-compatible` \| `ollama` \| `vllm` \| `gemini` \| `fake` |
| `base_url` | 空 = 用 provider 默认 |
| `api_key_env` | 环境变量名（如 `DEEPSEEK_API_KEY`）；与 `api_key` 二选一 |
| `api_key` | 直接给 key（只进 0600 的 llm_config.json） |
| `timeout` | 默认 120 秒 |
| `max_retries` | 默认 4（`stop_after_attempt = max_retries + 1`；429/5xx/网络错误可重试，4xx 非 429 不重试） |
| `reasoning_style` | `none` \| `deepseek` \| `openai` \| `openrouter`（默认 `deepseek`） |
| `tiers.strong/cheap/fast` | `{model, options{thinking, reasoning_effort, request_overrides}}` |

## Provider 默认连接（§4.5）

| provider | 默认 base_url | 默认 api_key_env | 需要 key |
|---|---|---|---|
| `deepseek` | `https://api.deepseek.com` | `DEEPSEEK_API_KEY` | ✅ |
| `openai` | `https://api.openai.com/v1` | `OPENAI_API_KEY` | ✅ |
| `openrouter` | `https://openrouter.ai/api/v1` | `OPENROUTER_API_KEY` | ✅ |
| `openai-compatible` | **必填** | 用户填 | 可配 |
| `ollama` | `http://localhost:11434/v1` | – | ❌ |
| `vllm` | **必填** | 可配 | 可配 |
| `gemini` | `https://generativelanguage.googleapis.com/v1beta/openai` | `GEMINI_API_KEY` | ✅ |
| `fake` | – | – | ❌（离线测试） |

## 推理方言（§4.5）

- `deepseek`：`extra_body.thinking={type:enabled/disabled}` + `reasoning_effort`（thinking 时）；`max_tokens = max(max_tokens, 4096)`（thinking 时）。
- `openai`：`reasoning_effort`（thinking 时）/ `"none"`；`max_completion_tokens`。
- `openrouter`：`extra_body.reasoning={effort:...}` / `{enabled:false}`。
- `openai-compatible`：由 `reasoning_style` 决定（none/deepseek/openai/openrouter）。
- `ollama` / `vllm` / `gemini`：兼容模式（无额外方言）。

## 各 Provider 配置示例

### deepseek（默认）
```json
{
  "provider": "deepseek",
  "api_key": "sk-xxxx",              // 或 "api_key_env": "DEEPSEEK_API_KEY"
  "reasoning_style": "deepseek",
  "max_retries": 4,
  "tiers": {
    "strong": {"model": "deepseek-v4-pro",   "options": {"thinking": true,  "reasoning_effort": "high"}},
    "cheap":  {"model": "deepseek-v4-flash", "options": {"thinking": true,  "reasoning_effort": "high"}},
    "fast":   {"model": "deepseek-v4-flash", "options": {"thinking": false}}
  }
}
```

### openai-compatible（任意 OpenAI 兼容网关）
```json
{
  "provider": "openai-compatible",
  "base_url": "https://your-gateway.example.com/v1",
  "api_key": "sk-xxxx",
  "reasoning_style": "none",
  "tiers": {
    "strong": {"model": "your-model", "options": {"thinking": false}},
    "cheap":  {"model": "your-model", "options": {"thinking": false}},
    "fast":   {"model": "your-model", "options": {"thinking": false}}
  }
}
```

### ollama（本地，免密）
```json
{
  "provider": "ollama",
  "base_url": "http://localhost:11434/v1",
  "reasoning_style": "none",
  "tiers": {
    "strong": {"model": "qwen2.5:14b", "options": {"thinking": false}},
    "cheap":  {"model": "qwen2.5:7b",  "options": {"thinking": false}},
    "fast":   {"model": "qwen2.5:7b",  "options": {"thinking": false}}
  }
}
```
「测试连接」：Ollama 有服务 → 返回 `pong`；无服务 → 可读错误（连接拒绝），不崩溃。

### fake（离线测试 / QA 全流程）
```json
{
  "provider": "fake",
  "fake_script": "/abs/path/to/rules.jsonl",
  "tiers": {"strong": {"model": "fake-model", "options": {"thinking": false}}}
}
```
**JSONL 规则格式**（每行一条，`when` 精确匹配 `stage` + 可选 `chunk`/`tier`；未命中 → `[]`（json_mode）或 `""`）：
```jsonl
{"when":{"stage":"S4_pre_extract"},"respond":{"terms":[]}}
{"when":{"stage":"S4_pre_extract","chunk":3},"respond":{"terms":[{"source":"御堂 静","target":"御堂静","type":"人物"}]}}
{"when":{"stage":"S4_translate","chunk":1},"respond":{"text":"第一章译文占位…"}}
{"when":{"stage":"S4_post_extract"},"respond":{"terms":[]}}
{"when":{"stage":"ping"},"respond":{"text":"pong"}}
```
- `respond.text` → 纯文本输出（翻译/梗概/风格/ping）；
- 其它键 → 作为 JSON 值原样输出（术语抽取/回抽的 `{terms:[...]}`）。
- fake 无网络请求、不计费，但照常走完整调用管线（含 usage 归一化：返回固定 usage 样例），
  QA 全流程离线可跑。

### openai / openrouter / vllm / gemini（骨架）
```json
{ "provider": "openai",    "api_key_env": "OPENAI_API_KEY",    "reasoning_style": "openai",    "tiers": { "strong": {"model": "gpt-5",  "options": {"thinking": true}}, "cheap": {"model": "gpt-5-mini", "options": {"thinking": false}}, "fast": {"model": "gpt-5-mini", "options": {"thinking": false}} } }
{ "provider": "openrouter", "api_key_env": "OPENROUTER_API_KEY", "reasoning_style": "openrouter", "tiers": { "strong": {"model": "anthropic/claude-sonnet-4", "options": {"thinking": true}}, "cheap": {"model": "anthropic/claude-haiku", "options": {"thinking": false}}, "fast": {"model": "anthropic/claude-haiku", "options": {"thinking": false}} } }
{ "provider": "vllm", "base_url": "http://localhost:8000/v1", "reasoning_style": "none", "tiers": { "strong": {"model": "Qwen/Qwen3-32B-AWQ", "options": {"thinking": false}}, "cheap": {"model": "Qwen/Qwen3-8B", "options": {"thinking": false}}, "fast": {"model": "Qwen/Qwen3-8B", "options": {"thinking": false}} } }
{ "provider": "gemini", "api_key_env": "GEMINI_API_KEY", "reasoning_style": "none", "tiers": { "strong": {"model": "gemini-2.5-pro", "options": {"thinking": true}}, "cheap": {"model": "gemini-2.5-flash", "options": {"thinking": false}}, "fast": {"model": "gemini-2.5-flash", "options": {"thinking": false}} } }
```

## 校验与连通性

```bash
$PY $SKILL/llm_tool.py validate --state <state> --config-file <llm_config.json>   # 退 0 = 通过；退 5 = 凭据/配置问题
$PY $SKILL/llm_tool.py ping    --state <state> --config-file <llm_config.json>   # 最小连通性（max_tokens=8）
$PY $SKILL/llm_tool.py usage   --state <state> --format md                       # 用量累计
```

## 计价参考（T10 成本估算）

`LLMUsage.totalCostEstimate(provider:)` 按「每百万 token 美元」官方价估算（可配置扩展）：

| provider | 输入 $/MTok | 输出 $/MTok | 缓存命中输入 $/MTok | 说明 |
|---|---|---|---|---|
| `deepseek` | 0.27 | 1.10 | 0.07 | deepseek-chat 官方价；输入 = 命中×缓存价 + 未命中×原价 |
| `openai` | 0.15 | 0.60 | – | gpt-4o-mini 官方价 |
| 其它 | – | – | – | 未知 provider → UI 显示「无法估算」 |

- 估算公式：`成本 = (缓存命中 tokens/1e6)×缓存价 + (未命中 tokens/1e6)×输入价 + (输出 tokens/1e6)×输出价`
  （deepseek 有缓存价；openai 无缓存价字段时按原输入价计）。
- `report.md` 的「API 用量」章节只列 token 数（totals/by_tier/by_stage + 缓存命中率），不含金额——
  金额估算在 UI 交付面板展示。
