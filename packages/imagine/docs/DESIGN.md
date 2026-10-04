# imagine 设计

## 目标

一句话：**用同一套 CLI 调用所有文生图 / 图生图模型，用户只表达想要什么，不关心各家接口差异。**

三条原则：

1. **用户面统一** —— 一套参数、一套输出、一套错误语义。
2. **差异只存在于适配器** —— 新增一家 provider 只加一个文件，不改核心。
3. **能力可声明** —— 脚本知道哪家支持什么。不支持时要么自动降级，要么给出「这家不支持 X」的明确错误，而不是把参数原样丢给上游换回一个 400。

## 现状问题

当前 621 行，provider 差异散落在 **6 处**：

| 位置 | 内容 | 改动成本 |
| --- | --- | --- |
| 20-57 | 5 个全局关联数组（host / model / ref-model / proxy prefix / key env） | 加一行 |
| 258-390 | 请求体构造，8 个 `case` 分支 | 加一段 |
| 403-415 | 响应解析，8 个 `case` 分支 | 加一段 |
| 521-540 | 模型列表，按 provider 分支 | 加一段 |
| 83-190 | 尺寸 / 端点 / 凭证解析中的 provider 特判 | 散落 |

后果有两个：

- **新增一家要改 6 个地方**，漏一处就是运行期才炸。
- **能力差异无法表达**。谁能传 `size`、size 用 `*` 还是 `x`、谁支持参考图、`n` 上限多少，全硬编码在分支里。用户于是看到上游的原始报错（`Invalid size '1024x768'. Supported sizes are ...`），而不是「这家不支持该尺寸，已为你改用 1024x1024」。

## 设计

### 三层结构

```
imagine.sh                    入口：CLI 解析、provider 选择、编排、落盘
lib/core/compose.sh           核心：尺寸决策、输出归一、下载、凭证解析
lib/providers/<name>.sh       适配器：一家一个文件，声明能力 + 两个函数
lib/common.sh                 项目内共享小工具
```

适配器目录用 `import providers/cloudflare` 装载（`tools/build` 已支持入口目录下的包私有模块）。

### 适配器契约

一个 provider 文件长这样，**没有分支、没有隐藏约定**：

```bash
# lib/providers/cloudflare.sh

provider_meta() {
	PROVIDER_LABEL="Cloudflare Workers AI"

	# 凭证：名字 = 环境变量名，多个用空格分隔
	PROVIDER_CREDS=(CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID)

	PROVIDER_DEFAULT_MODEL="@cf/black-forest-labs/flux-1-schnell"

	# 能力声明：核心据此决定映射、降级或报错
	PROVIDER_CAPS="size:fixed ref:none seed:yes negative:no quality:no n:1"
	PROVIDER_SIZES=(1024x1024)      # size:fixed 时的集合
}

provider_endpoint() { # $1=model  →  echo 完整 URL
	echo "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/ai/run/$1"
}

provider_auth() { # → echo curl 用的 header 行
	echo "Authorization: Bearer $CLOUDFLARE_API_TOKEN"
}

provider_body() { # 读 $PROMPT $MODEL $SIZE $COUNT $SEED $REF... → echo JSON
	...
}

provider_parse() { # $1=响应 JSON → 设 IMAGINE_RESULT_TYPE/IMAGINE_RESULTS
	IMAGINE_RESULT_TYPE=base64
	IMAGINE_RESULTS=$(jq -r '.result.image' <<< "$1")
}
```

契约要点：

- **`PROVIDER_CAPS` 是唯一的能力真相**。核心层只读它，不看 provider 名。
- **`provider_parse` 只产出两种结果之一**：`url`（换行分隔的 URL 列表）或 `base64`（换行分隔的 base64）；核心负责下载或解码落盘。适配器不碰文件系统。
- **`provider_body` 可以随便差**——这是适配器存在的意义——但它必须自己把能力边界内的事做对。

### 能力声明带来的三个好处

**1. 尺寸自动映射。** 核心按 `PROVIDER_CAPS` 处理：

| 声明 | 行为 |
| --- | --- |
| `size:any` | 原样传，格式 `1024x768` |
| `size:star` | 转成 `1024*768`（dashscope） |
| `size:fixed` | 从 `PROVIDER_SIZES` 里挑宽高比最接近的（openrouter、cloudflare） |
| `size:none` | 忽略用户传的尺寸并以 warn 提示 |

用户永远只写 `--ar 16:9` 或 `-s 1024x768`，映射是脚本的事。

**2. 不支持的参数提前拦。** `--negative-prompt` 遇到 `negative:no` 时 warn 一行并跳过，而不是让上游报 400。

**3. 数量上限自动收敛。** `n:9` 遇到 `-n 20` 时降到 9 并提示。

### 用户面

```bash
imagine -p "a red apple on a wooden table"              # 自动挑可用 provider
imagine -p "..." --ar 16:9 -o out.png                   # 宽高比，脚本负责映射
imagine -p "..." --ref ref.png -o out.png               # 图生图
imagine -p "..." --provider cloudflare -m @cf/...       # 指定
imagine --provider dashscope --extra prompt_extend=false  # 透传 provider 特有参数
imagine models                                          # 列可用模型
imagine providers                                       # 列各家能力与凭证状态
```

**provider 自动选择**：按「免费优先、有凭证、支持所需能力」排序（agnes → cloudflare → 其他），命中即用。用户不指定 `--provider` 时不再报错要求选择。

**`imagine providers`** 直接打印能力表（含凭证是否已配置），把 README 里那张表变成可执行的东西。

## Cloudflare 接入

已确认可用，接入要点（与现有 provider 的差异正好考验这套抽象）：

| 项 | 值 |
| --- | --- |
| 端点 | `POST https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/ai/run/{model}` |
| 凭证 | `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID`（**两个**，现有都是单 key） |
| 默认模型 | `@cf/black-forest-labs/flux-1-schnell` |
| 请求体 | `{prompt, seed?}` —— **没有 size 参数** |
| 响应 | `{result: {image: "<base64>"}, success, errors}` |
| 错误 | `success: false` + `errors[]`，HTTP 状态可能仍是 200 |
| 图生图 | flux-1-schnell 不支持；FLUX.2 Dev 支持多参考图编辑 |

所以适配器需要 `PROVIDER_CREDS` 支持**多凭证**，并且 `provider_parse` 之外要能处理「HTTP 200 但 success=false」——这一条建议提升为核心层的通用检查：适配器声明 `PROVIDER_ERROR_PATH='.success'`，核心统一判错。

模型名含 `/` 和 `@`，放进 URL 路径即可，无需转义。

## 迁移路径

分四步，每步都可独立验证、不破坏现有功能：

1. **抽出适配器契约**：把现有 8 家的映射表 + body 构造 + 响应解析分别搬进 `lib/providers/<name>.sh`，核心改成按 `PROVIDER_CAPS` 决策。功能等价，用现有测试兜底。
2. **核心层通用化**：尺寸映射、多凭证、`success:false` 检查、`n` 收敛、能力警告。
3. **接入 cloudflare**，验证「新增一家只加一个文件」这条设计目标是否真的成立。
4. **加 `imagine providers` 与自动选 provider**，把 README 的能力表变成命令输出。

每步之间跑 `tools/test`；第 1 步之后加一条「新增假 provider」的测试，用来防止契约腐化。

## 待决问题

1. **`quality` / `style` 的归属**：现在只有部分 provider 认，是否该像 `size` 一样进能力表？
2. **输出格式**：各家返回 PNG / JPEG 不一，是否统一转 PNG（引入依赖），还是保持原样并在文件名上体现？
3. **自动选 provider 的排序依据**：免费优先 + 能力匹配，但「免费」是硬编码事实（agnes、cloudflare 免费），要不要允许用户用配置文件覆盖优先级？
4. **本地缓存**：同 prompt + 参数是否缓存结果，避免重复计费？
