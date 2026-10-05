---
name: image-gen
description: 命令行文生图 / 图生图，一套参数调用多家 provider（OpenAI、Google、DashScope、Z.AI、MiniMax、Doubao、Agnes、OpenRouter、Cloudflare）。当用户要求生成、绘制、创建图片，或给一张参考图改风格 / 保持身份改图时使用。
license: MIT
compatibility: 需要 bash 4.3+、curl、jq。脚本在 `scripts/imagine`（相对本文件目录）。
metadata:
  version: "0.3.0"
---

# image-gen

用同一套参数调用多家文生图 API。脚本入口是 **`scripts/imagine`**（相对本 SKILL.md 所在目录）。

核心原则：用户只表达想要什么（提示词、宽高比、参考图），各家接口差异由脚本映射，不支持的能力会明确提示或报错，而不是把参数丢给上游换回 400。

## 快速开始

```bash
scripts/imagine -p "a red apple on a wooden table"                  # 自动挑可用 provider
scripts/imagine -p "..." --ar 16:9 -o out.png                       # 按宽高比
scripts/imagine -p "..." --quality 2k -o out.png                    # 分辨率档位 normal|2k（默认 normal）
scripts/imagine -p "..." --ref ref.png -o out.png                   # 图生图（参考图改风格）
scripts/imagine -p "..." --provider dashscope -m qwen-image-plus -o out.png
scripts/imagine --provider dashscope --extra parameters.prompt_extend=false -p "..." -o out.png
scripts/imagine --json -p "..." -o out.png                          # 结果以 JSON 写到 stdout
scripts/imagine providers                                           # 列能力与凭证状态
scripts/imagine models [provider]                                   # 列默认模型 / 全部模型
scripts/imagine update                                              # 手动刷新模型目录
```

先跑 `scripts/imagine providers` 确认哪家有凭证；不指定 `--provider` 时脚本自动选（免费优先：agnes → cloudflare → 其他）。

## 选项

| 选项 | 说明 |
| --- | --- |
| `-p, --prompt` | 提示词 |
| `-P, --promptfile` | 从文件读提示词（与 `-p` 合并） |
| `-o, --output` | 输出文件或目录（目录 / 省略时自动命名） |
| `--provider` | 指定 provider；缺省自动选择 |
| `-m, --model` | 模型 ID；优先级 `--model` > `<PROVIDER>_IMAGE_MODEL` > 模型目录 > 内置默认 |
| `--ar` | 宽高比，如 `16:9`、`4:3`、`2.35:1` |
| `-s, --size` | 显式尺寸，如 `1024x768`（优先于 `--ar`） |
| `-q, --quality` | 分辨率档位 `normal`（默认）或 `2k` |
| `-n, --count` | 生成数量（超过该 provider 上限会自动收敛并提示） |
| `--seed` | 随机种子（整数） |
| `--negative-prompt` | 负面提示词（部分 provider 支持） |
| `--ref` | 参考图路径，多个用逗号分隔 |
| `--style` | 风格预设（仅 OpenAI dall-e-3 等） |
| `--extra k=v,...` | 透传 provider 特有参数，支持点号路径（如 `parameters.prompt_extend=false`） |
| `--json` | 结果以 JSON 输出到 stdout（日志仍在 stderr） |

## 输出

- 普通模式：图片落盘，路径由 `-o` 决定；日志在 stderr。
- `--json`：stdout 输出一行 JSON，便于脚本消费：

```json
{"ok":true,"provider":"agnes","model":"agnes-image-2.1-flash","requested_size":"1024x1024",
 "size":"1024x1024","aspect":"1:1","count":1,"attempts":1,"files":["/tmp/imj.png"]}
```

失败时 `ok:false` 并带 `error` 字段，退出码非 0。日志一律走 stderr，stdout 只有 JSON。

## 环境变量

| 变量 | 用途 |
| --- | --- |
| `OPENAI_API_KEY` / `GOOGLE_API_KEY` / `DASHSCOPE_API_KEY` / `ZAI_API_KEY` / `MINIMAX_API_KEY` / `ARK_API_KEY` / `AGNES_API_KEY` / `OPENROUTER_API_KEY` | 各家 key |
| `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` | Cloudflare Workers AI（两个） |
| `<PROVIDER>_IMAGE_MODEL` | 逐家覆盖默认模型，如 `DASHSCOPE_IMAGE_MODEL=qwen-image-3.0-pro` |
| `XGET_BASE_URL` | 代理 base（仅对声明了前缀的 provider 生效） |
| `IMAGINE_TIMEOUT` | 请求超时秒数，默认 120 |
| `IMAGINE_RETRY` | 可恢复失败的重试次数，默认 2（4xx 不重试） |
| `IMAGINE_REGISTRY_URL` / `IMAGINE_REGISTRY_TTL_HOURS` / `IMAGINE_REGISTRY_OFF` | 模型目录源 / 刷新间隔 / 关闭回源 |

凭证可放包目录 `.env`；注意 `.env` 会覆盖同名环境变量（需环境变量优先时，`.env` 内用 `: "${VAR:=...}"` 写法）。

## 行为约定（给 agent）

- **自动选 provider**：不指定时挑免费且凭证齐全的（agnes → cloudflare → 其他），不要手动硬编码 provider，除非用户指定。
- **尺寸**：用 `--ar` 或 `-s`，不要自己换算像素；`size:fixed` 的 provider 会就近映射并 warn。
- **图生图**：`--ref <path>`；不支持参考图的 provider 会直接报错，换一家或去掉 `--ref`。
- **不支持的可选参数**（如某些家的 `--negative-prompt`/`--seed`）会 warn 后忽略，不用刻意规避。
- **稳定性**：免费层有速率限制，偶发超时；脚本本身会重试 `IMAGINE_RETRY` 次，仍失败可稍后重跑。
- **取结果文件**：优先用 `--json` 解析 `files`，不要靠读目录猜文件名。

## 常见故障

| 现象 | 处理 |
| --- | --- |
| `缺少凭证` / `没有可用的 provider` | 在环境或包目录 `.env` 里配对应的 key；先跑 `providers` |
| `HTTP 4xx` | 参数或凭证问题，脚本不重试；看 stderr 的上游 message |
| 超时 / 响应截断 | 免费层限流或网络抖动；脚本已重试，可调大 `IMAGINE_TIMEOUT` 后重跑 |
| 落盘内容不是图片 | 上游返回错误页，已自动删除文件；重跑或换 provider |
