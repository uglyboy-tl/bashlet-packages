# imagine

命令行文生图 / 图生图工具：**一套参数调用所有 provider**，用户只表达想要什么，不关心各家接口差异。

```bash
imagine -p "a red apple on a wooden table"              # 自动挑可用 provider
imagine -p "..." --ar 16:9 -o out.png                   # 宽高比由脚本映射
imagine -p "..." --quality 2k -o out.png                # 分辨率档位 normal|2k（默认 normal）
imagine -p "..." --ref ref.png -o out.png               # 图生图
imagine -p "..." --provider cloudflare -m @cf/...       # 指定 provider / 模型
imagine --provider dashscope --extra parameters.prompt_extend=false  # 透传 provider 特有参数
imagine providers                                       # 哪家能用（打只读端点验证 key）+ 缺什么
imagine models [provider]                               # 列默认模型 / 全部模型
imagine update                                          # 手动同步刷新模型目录（唯一阻塞网络的操作）
imagine --json -p "..." -o out.png                       # 结果以 JSON 写到 stdout（日志仍在 stderr）
```

## 设计原则

1. **用户面统一**：一套参数、一套输出、一套错误语义。
2. **差异只存在于适配器**：新增一家 provider 只加一个文件。
3. **能力可声明**：`PROVIDER_CAPS` 是唯一的能力真相。脚本据此自动降级或给出明确错误，而不是把参数原样丢给上游换回 400。

## 结构

```
imagine.sh                  入口：CLI 解析、provider 选择、编排、落盘
lib/provider.sh             注册表：适配器注册、能力查询、凭证检查、自动选择
lib/registry.sh             模型目录：本地缓存优先，远端异步刷新
lib/openai_compat.sh        OpenAI 兼容 images 接口的公共实现（5 家 adapter 复用）
lib/size.sh                 尺寸决策：宽高比 / 尺寸归一 + 按能力映射
lib/compose.sh              生成编排：请求、能力收敛、调用适配器、重试、落盘
lib/common.sh               共享小工具：参考图拼装、输出路径、--extra 解析
lib/providers/index.sh      适配器装载表（新增一家：加文件 + 这里加一行）
lib/providers/<name>.sh     适配器：声明能力 + 实现函数
registry.toml               模型目录数据（默认模型 + 模型清单，本文件人工维护）
scripts/update-registry.sh  维护者/CI：调 imagine models --live 刷新 models 字段
SKILL.md                    agent skill 定义（脚本路径 scripts/imagine）
```

`lib/providers/` 是包私有模块（不走 bashlet 的 core/std/ext 链接）；`import providers/agnes` 即可装载。

## 适配器契约

```bash
# lib/providers/example.sh
provider_example_meta() {
	PROVIDER_LABEL="Example"
	PROVIDER_CREDS=(EXAMPLE_API_KEY)        # 多个凭证空格分隔
	PROVIDER_DEFAULT_MODEL="example-image"
	PROVIDER_DEFAULT_REF_MODEL="example-image"
	PROVIDER_CAPS="size:any ref:multi seed:yes negative:no quality:no style:no n:4"
	PROVIDER_SIZES=()                       # size:fixed 时的候选集合
	PROVIDER_HOST="api.example.com"
	PROVIDER_XGET_PREFIX=""                 # 走 XGET 代理时的路径前缀
	PROVIDER_PROBE_PATH="/v1/models"        # 只读探活端点，供 `providers` 验证 key
	PROVIDER_FREE=false
}
provider_example_auth() { requests.auth_bearer "$EXAMPLE_API_KEY"; }
provider_example_endpoint() { printf '/v1/images/generations'; }
provider_example_body() { ...; }            # 读 PROMPT/MODEL/SIZE/ASPECT/COUNT/SEED/... → echo JSON
provider_example_parse() { ...; }           # $1=响应 JSON → 设 IMAGINE_RESULT_TYPE/IMAGINE_RESULTS
provider_example_models() { ...; }          # 可选；输出换行分隔的模型 ID
provider.register example
```

- **`PROVIDER_PROBE_PATH`**（可选）：只读探活端点（相对 `PROVIDER_HOST`），`imagine providers` 用它确认 key 真的能用，而不是只判断变量存不存在。不声明就显示「没有只读端点，无法验证」。
- **`PROVIDER_CAPS`**：`size` 取 `any`（原样）/`star`（星号分隔）/`fixed`（就近映射到 `PROVIDER_SIZES`）/`aspect`（只给宽高比）/`none`（忽略）；`ref` 取 `none`/`one`/`multi`；`seed`/`negative`/`quality`/`style` 取 `yes`/`no`；`n` 为单次上限。
- **`provider_parse` 只产出两种结果之一**：`IMAGINE_RESULT_TYPE=url`（换行分隔 URL）或 `base64`（换行分隔 base64）。适配器不碰文件系统。
- **HTTP 200 也可能是业务错误**：由适配器的 `_parse` 自行判错并 `return 1`（如 Cloudflare 的 `success=false`、MiniMax 的 `base_resp.status_code`）。

## 能力收敛

| 声明 | 行为 |
| --- | --- |
| `size:star` | `1024x768` → `1024*768` |
| `size:fixed` | 从 `PROVIDER_SIZES` 挑宽高比最接近的 |
| `size:aspect` | 只传宽高比（Google） |
| `size:none` | 忽略尺寸并 warn |
| `n:N` | `-n` 超过 N 时收敛到 N 并提示 |
| `quality:no` | `--quality 2k` warn 后按默认分辨率处理 |
| `ref:none` | 传 `--ref` 直接报错，不发给上游 |
| `negative/quality/style:no` | 传了就 warn 一行并忽略 |

## 模型目录

默认模型与模型清单来自 `registry.toml`（仓库里的全局数据）：

- **读**：本地缓存优先，前台永不联网；首次运行用适配器兜底生成种子写入缓存。
- **刷**：缓存超过 `IMAGINE_REGISTRY_TTL_HOURS`（默认 24）时后台异步回源，失败不影响本次生成。
- **优先级**：`--model` > `<PROVIDER>_IMAGE_MODEL` > 目录 > 适配器兜底；模型清单为 目录缓存 > 适配器内置 > 活的 API（最后手段）。
- **手动刷新**：`imagine update`（打印变更摘要，是唯一阻塞网络的操作）。
- **维护**：`registry.toml` 是普通数据文件，**手动编辑和脚本更新等价**，都建议走 PR 评审，欢迎社区提 PR 增删模型。`models` 也可用 `scripts/update-registry.sh` 从活的 API 合并刷新（仓库带 `.github/workflows/update-registry.yml`，定时开 PR）；脚本只合并不删除、不碰 `default_model`。客户端由 `imagine update` 刷新缓存，或按 TTL 后台自动刷新。

详见 `docs/registry.md`。

## 环境变量

| 变量 | 用途 |
| --- | --- |
| `OPENAI_API_KEY` / `GOOGLE_API_KEY` / `DASHSCOPE_API_KEY` / `ZAI_API_KEY` / `MINIMAX_API_KEY` / `ARK_API_KEY` / `AGNES_API_KEY` / `OPENROUTER_API_KEY` | 各家 API key |
| `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` | Cloudflare Workers AI（两个） |
| `<PROVIDER>_IMAGE_MODEL` | 逐家覆盖默认模型，如 `DASHSCOPE_IMAGE_MODEL=qwen-image-3.0-pro` |
| `IMAGINE_REGISTRY_URL` | 模型目录源，默认仓库 raw 地址 |
| `IMAGINE_REGISTRY_TTL_HOURS` | 后台刷新间隔小时数，默认 24 |
| `IMAGINE_REGISTRY_OFF` | 设为非空则不回源（纯离线/调试） |
| `XGET_BASE_URL` | 走 XGET 代理时作为 base；仅对声明了前缀的 provider 生效 |
| `IMAGINE_TIMEOUT` | 请求超时秒数，默认 120 |
| `IMAGINE_RETRY` | 可恢复失败的重试次数，默认 2（4xx 不重试） |

凭证放包目录的 `.env`（已 gitignore），或用真实环境变量。模板见 `env.example`：
`cp env.example .env && chmod 600 .env`，里面逐家写了去哪拿 key、默认模型是什么、缺了会怎样。

注意：`.env` 由入口在 `import` 之前 source，条目一律写 `: "${VAR:=...}"`（变量未设或为空才赋值），因此**环境里已设的非空同名变量优先**。`.env` 含密钥，建议 `chmod 600`。格式规范见 [`docs/env-example.md`](../../docs/env-example.md)。

## Provider 现状

`imagine providers` 会**探活**（并发打各家一个只读端点）并打印上面那张表：可用的给详情，
不可用的只给一行原因；`--offline` 只读配置不发请求，`--caps` 附带尺寸/参考图/张数。
下面这张表是**生成接口**的实测记录（2026-10-04），与探活无关。

| provider | 免费 | 实测 | 备注 |
| --- | --- | --- | --- |
| agnes | 是 | 通过 | 全线模型免费；免费层有速率限制 |
| cloudflare | 是 | 通过 | flux-1-schnell；无 size 参数，实测不接受 seed；两个凭证 |
| google | 否 | 通过 | size 用 aspectRatio |
| dashscope | 否 | 通过 | size 必须星号；参考图模式 n 固定 1 |
| doubao | 否 | 通过 | 尺寸有最低像素要求；无尺寸时用 `2K` |
| minimax | 否 | 通过 | 宽高分开传；单次最多 9 张 |
| openrouter | 否 | 通过 | 尺寸只能是固定集合；上游有地区限制 |
| openai | 否 | 未测 | 本机无 key |
| zai | 否 | 未测 | 本机无 key |

## 接口备忘

各家接口对同一概念的要求并不一致，以下是实际踩出来的。

### 尺寸格式不统一

- **dashscope**：`1024*768`（星号）。传 `1024x768` 直接 400。
- **openrouter**：只接受 `1024x1024` / `1024x1536` / `1536x1024` / `auto`，按宽高比映射。
- **google**：只认 `aspectRatio`，脚本把尺寸反推成宽高比。
- **cloudflare**：无 size 参数。
- **其余**：`1024x768` 形式。

### 响应字段的坑

- **agnes**：URL 输出模式下 `b64_json` 返回**空字符串** `""` 而非 `null`，jq 的 `//` 不回退，必须显式排除空串再回退到 `url`。
- **cloudflare**：HTTP 200 也可能是 `success:false`。
- **minimax**：HTTP 200 也可能是 `base_resp.status_code != 0`。

### 速率与地区

- **agnes 免费层有速率限制**，连续发图可能超时（表现为 HTTP status 0）；隔一会儿重试即可。
- **openrouter 对 OpenAI / Anthropic / Google 上游模型有账号级地区限制**，中国大陆 IP 可能收到地区不支持错误。

## 测试

```bash
tools/test imagine          # 全部离线用例 + 2 个真实生图（agnes 免费）
```

生图用例会真实调用 API。连续执行可能触发 agnes 免费层速率限制，重跑即可。
