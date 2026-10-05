# imagine 设计

> 状态：已落地（2026-10-04）。本文件描述目标与最终结构；实现细节以代码为准。

## 目标

一句话：**用同一套 CLI 调用所有文生图 / 图生图模型，用户只表达想要什么，不关心各家接口差异。**

三条原则：

1. **用户面统一** —— 一套参数、一套输出、一套错误语义。
2. **差异只存在于适配器** —— 新增一家 provider 只加一个文件，不改核心。
3. **能力可声明** —— 脚本知道哪家支持什么。不支持时要么自动降级，要么给出「这家不支持 X」的明确错误，而不是把参数原样丢给上游换回一个 400。

## 结构

```
imagine.sh                  入口：CLI 解析、provider 选择、编排
lib/provider.sh             注册表：注册、能力查询、凭证检查、自动选择
lib/registry.sh             模型目录：本地缓存优先，远端异步刷新
lib/openai_compat.sh        OpenAI 兼容 images 接口公共实现
lib/size.sh                 尺寸决策：归一 + 按能力映射
lib/compose.sh              生成编排：请求、能力收敛、调用适配器、重试、落盘
lib/common.sh               共享小工具：参考图拼装、输出路径、--extra 解析
lib/providers/index.sh      适配器装载表：新增一家 = 加文件 + 加一行 import
lib/providers/<name>.sh     适配器：一家一个文件，声明能力 + 五个函数
registry.toml               模型目录数据（默认模型 + 模型清单）
scripts/update-registry.sh  维护者/CI：调 `imagine models --live` 刷新 models
SKILL.md                    agent skill 定义（脚本路径 scripts/imagine）
```

适配器目录是**包私有模块**（`lib/providers/`），用 `import providers/<name>` 装载。
注意：包内 `lib/core`、`lib/std`、`lib/ext` 是指向 bashlet 的符号链接，包私有模块只能放 `lib/` 根或自建子目录，不能放这三个目录里。

### 与原设计的偏差

| 原设计 | 落地 | 原因 |
| --- | --- | --- |
| `lib/core/compose.sh` | `lib/compose.sh` | `lib/core` 是 bashlet 链接，不可写 |
| 适配器函数写作 `provider_endpoint()` | `provider_<name>_endpoint()` | 所有适配器在同一 shell 内共存，必须命名空间隔离 |
| `PROVIDER_ERROR_PATH='.success'` 统一判错 | 适配器 `_parse` 自行判错 | MiniMax 的判据不是布尔路径，统一钩子更简单 |
| 能力表只有 size/ref/n | 增加 `seed`/`negative`/`quality`/`style` 与 `size:aspect` | Google 只认宽高比；quality/style 各一家认，同类问题同一机制 |

## 适配器契约

```bash
# lib/providers/example.sh
provider_example_meta() {
	PROVIDER_LABEL="Example"
	PROVIDER_CREDS=(EXAMPLE_API_KEY)        # 名字 = 环境变量名，多个空格分隔
	PROVIDER_DEFAULT_MODEL="example-image"
	PROVIDER_DEFAULT_REF_MODEL="example-image"
	PROVIDER_CAPS="size:any ref:multi seed:yes negative:no quality:yes style:no n:4"
	PROVIDER_SIZES=()                       # size:fixed 时的候选集合
	PROVIDER_HOST="api.example.com"
	PROVIDER_XGET_PREFIX=""                 # 走 XGET 代理时的路径前缀
	PROVIDER_FREE=false                     # 免费层优先
	PROVIDER_MODEL_LIST=""                  # 可选：无模型列表接口时的静态列表
}
provider_example_auth() { requests.auth_bearer "$EXAMPLE_API_KEY"; }
provider_example_endpoint() { printf '/v1/images/generations'; }   # $1=model
provider_example_body() { ...; }            # 读 PROMPT/MODEL/SIZE/ASPECT/IMAGE_SIZE/COUNT/SEED/... → echo JSON
provider_example_parse() { ...; }           # $1=响应 JSON → 设 IMAGINE_RESULT_TYPE/IMAGINE_RESULTS
provider_example_models() { ...; }          # 可选
provider.register example
```

契约要点：

- **OpenAI 兼容的适配器薄壳化**：openai / agnes / zai / doubao / openrouter 共用 `lib/openai_compat.sh`（bearer 认证 + `{model,prompt,n,size[,seed]}` + `data[].b64_json|url`），适配器只声明端点路径，并把差异（额外字段 / 参考图 / 尺寸与数量覆盖）作为参数传入。新增一家 OpenAI 兼容 provider 基本只是 meta + 几行 body。
- **`PROVIDER_CAPS` 是唯一的能力真相**。核心层只读它，不看 provider 名。
- **`provider_<name>_parse` 只产出两种结果之一**：`url`（换行分隔 URL）或 `base64`（换行分隔 base64）；核心负责下载或解码落盘。适配器不碰文件系统。
- **HTTP 200 也可能是业务错误**：由 `_parse` 自行判错并 `return 1`（Cloudflare 的 `success=false`、MiniMax 的 `base_resp.status_code`）。
- **`_body` 可以随便差**（这是适配器存在的意义），但必须自己把能力边界内的事做对。

## 能力声明带来的三个好处

**1. 尺寸自动映射。** 核心按 `PROVIDER_CAPS` 处理：

| 声明 | 行为 |
| --- | --- |
| `size:any` | 原样传（`1024x768`） |
| `size:star` | 转成 `1024*768`（dashscope） |
| `size:fixed` | 从 `PROVIDER_SIZES` 里挑宽高比最接近的（openrouter） |
| `size:aspect` | 只给宽高比（google） |
| `size:none` | 忽略用户传的尺寸并以 warn 提示（cloudflare） |
| `quality:yes` | `--quality normal\|2k` 改变目标分辨率（normal 短边约 1024，2k 长边 2048） |

用户永远只写 `--ar 16:9` 或 `-s 1024x768`，映射是脚本的事。

**2. 不支持的参数提前拦。** `--negative-prompt` 遇到 `negative:no` 时 warn 一行并跳过；`--ref` 遇到 `ref:none` 时直接报错。

**3. 数量上限自动收敛。** `n:9` 遇到 `-n 20` 时降到 9 并提示。

## 模型目录（registry）

默认模型/模型清单不写死在脚本里，放 `registry.toml`（仓库 raw URL 为全局数据源）：

- 前台读本地缓存，**永不联网**；无缓存时用适配器兜底生成种子。
- 缓存过期（默认 24h）时后台异步回源，校验后原子替换；失败只写日志，不影响生成。
- 模型解析：`--model` > `<PROVIDER>_IMAGE_MODEL` > 目录 > 适配器兜底。
- `imagine update` 手动同步刷新；`registry.toml` 人工维护，`models` 可用 `scripts/update-registry.sh` 拉活清单（CI 定时）。

详见 `docs/REGISTRY.md`。

## 用户面

```bash
imagine -p "a red apple on a wooden table"              # 自动挑可用 provider
imagine -p "..." --ar 16:9 -o out.png                   # 宽高比，脚本负责映射
imagine -p "..." --quality 2k -o out.png                # 分辨率档位 normal|2k（默认 normal）
imagine --json -p "..." -o out.png                       # 结果以 JSON 写到 stdout
imagine -p "..." --ref ref.png -o out.png               # 图生图
imagine -p "..." --provider cloudflare -m @cf/...       # 指定
imagine --provider dashscope --extra parameters.prompt_extend=false  # 透传 provider 特有参数
imagine models [provider]                               # 列可用模型
imagine providers                                       # 列各家能力与凭证状态
```

**provider 自动选择**：按「免费优先、有凭证、支持所需能力」排序（agnes → cloudflare → 其他），命中即用。不指定 `--provider` 时不再报错。

**`imagine providers`** 直接打印能力表（含凭证是否已配置），把 README 里那张表变成可执行的东西。

## Cloudflare 接入

已确认可用（实测 2026-10-04，flux-1-schnell 约 6s 出图）。

| 项 | 值 |
| --- | --- |
| 端点 | `POST https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/ai/run/{model}` |
| 凭证 | `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID`（两个） |
| 默认模型 | `@cf/black-forest-labs/flux-1-schnell` |
| 请求体 | `{prompt}` —— 没有 size 参数，实测也不接受 seed（`Additional properties '/seed' not allowed`） |
| 响应 | `{result: {image: "<base64>"}, success, errors}` |
| 错误 | `success: false` + `errors[]`，HTTP 状态可能仍是 200 |
| 图生图 | flux-1-schnell 不支持；FLUX.2 Dev 支持多参考图编辑，但其接口是 multipart，暂未接入，故声明 `ref:none` |

多凭证由 `PROVIDER_CREDS` 数组表达；模型名含 `/` 和 `@`，直接放进 URL 路径即可。

## 重试分层

失败分两类：**传输层**（curl 连接失败/超时/响应截断）与**语义层**（HTTP 200 但 JSON 非法/无图）。两者分层处理：

- **传输层进框架**：`ext/requests` 现在把 curl 退出码纳入 `success` 判定——HTTP 200 但响应被截断不再算成功（新增 `requests.exit_code`）。这是通用缺陷修正，所有消费者受益。
- **重试策略留在业务层**：重试与否取决于业务语义（4xx 是参数/凭证问题不该重试，5xx/超时/坏 JSON 才该），所以重试循环放在 `compose`：整体重跑 build→post→校验，`IMAGINE_RETRY` 控制次数（默认 2），退避 `attempt*2` 秒。
- **不用 curl 原生 `--retry`**：它对失败语义不可控（POST 幂等性 / 重复计费 / 200 坏 JSON 覆盖不到）；框架虽支持经 `requests.init` 透传 curl 参数，但默认不开启。
- **暂不沉淀通用 `retry` 模块**：重试判定依赖业务语义，目前只有一个消费者；等第二个包需要再抽（YAGNI）。

## 待决问题的处置

1. **quality / style 归属**：已进能力表。`quality` 现为分辨率档位 `normal|2k`（非原生 quality 字符串），adapter 可自行映射到原生字段（如 OpenAI 的 `quality=medium|high`）；`style` 仍为原样透传（仅 dall-e-3）。
2. **输出格式**：保持原样，不引入转 PNG 依赖；文件名不体现真实格式（cloudflare 返回 JPEG 但默认名 `.png`）。留待需要时再做嗅探。
3. **自动选 provider 排序**：`PROVIDER_FREE` + 注册顺序（免费优先）。配置文件覆盖优先级属 YAGNI，未做。
4. **本地缓存**：未做（YAGNI）；重复计费风险由用户自行管理。

## 迁移结果

1. ✅ 抽出适配器契约：9 家映射表、body 构造、响应解析全部搬进 `lib/providers/<name>.sh`，核心按 `PROVIDER_CAPS` 决策。
2. ✅ 核心层通用化：尺寸映射、多凭证、`success:false` 检查、`n` 收敛、能力警告。
3. ✅ 接入 cloudflare，验证「新增一家只加一个文件 + 装载表一行」。
4. ✅ 加 `imagine providers` 与自动选 provider。
5. ✅ 加「新增假 provider」的单测，防止契约腐化。
