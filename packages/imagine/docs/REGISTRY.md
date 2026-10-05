# imagine 模型目录（registry）设计

> 状态：已实现（2026-10-05）。实现细节以 `lib/registry.sh` 为准。

## 问题

上游模型会变（新增、下线、改名、默认模型换代），而默认模型映射目前写死在 `lib/providers/*.sh` 里。改一次就得发版，用户也只能等新版。

参照 binup 的包目录：把「会变的数据」放仓库里的 TOML，用户端读本地缓存，后台异步回源刷新。

## 核心流程：本地缓存优先，远端异步刷新

```
读路径（前台，永不联网）:
  缓存不存在 ──→ 用脚本内置兜底写入缓存（种子）──→ 读缓存
  缓存存在   ──→ 直接读缓存

刷新路径（后台，失败无影响）:
  缓存过期 ──→ 后台进程拉远端 → 校验 → 原子替换缓存
```

一句话：**兜底不是「缓存缺失时的分支」，而是缓存的第一份种子。** 这样只有一条读取路径，没有 if-else 兜底逻辑。

好处：

- 首次运行、离线、断网都能立即工作（种子自带默认模型）。
- 任务执行路径零网络等待；远端慢/挂都不影响出图。
- 远端数据与种子同构，远端一到位就自然覆盖。

## 数据分层

| 层 | 位置 | 作用 | 可变性 |
| --- | --- | --- | --- |
| 兜底/种子 | 适配器里的 `PROVIDER_DEFAULT_MODEL` / `PROVIDER_MODEL_LIST` | 生成第一份缓存；缓存缺某家时兜底 | 随代码发版 |
| 本地缓存 | `ext/requests.cache`（XDG cache） | **唯一读取源**，含种子与远端内容 | 异步替换 |
| 远端目录 | `packages/imagine/registry.toml`（raw URL） | 全局单一数据源 | 改文件后逐步生效 |

**全局数据** = 仓库里那一个 `registry.toml`，所有用户从同一个 URL 刷新。不做每用户本地写回（会分叉）。

## registry.toml

```toml
# imagine 模型目录
# 默认源：https://github.com/uglyboy-tl/bashlet-packages/raw/HEAD/packages/imagine/registry.toml
# 换源：IMAGINE_REGISTRY_URL 环境变量 > 下面这行的默认值

[providers.agnes]
default_model = "agnes-image-2.1-flash"
default_ref_model = "agnes-image-2.1-flash"
models = "agnes-image-2.5-flash agnes-image-2.1-flash agnes-image-2.0-flash"

[providers.dashscope]
default_model = "qwen-image-plus"
default_ref_model = "wan2.7-image-pro"
models = "qwen-image-plus qwen-image-2.0-pro wan2.7-image-pro"

[providers.cloudflare]
default_model = "@cf/black-forest-labs/flux-1-schnell"
models = "@cf/black-forest-labs/flux-1-schnell @cf/black-forest-labs/flux-2-dev"
```

- 字段只有三个：`default_model`、`default_ref_model`、`models`（空格分隔，兼容 bashlet 的 TOML 解析器）。
- **能力声明 `PROVIDER_CAPS` 不进目录**：那是接口机制（size 格式 / ref 协议 / n 上限），属于适配器职责，不是「会变的数据」。
- 模型级能力（如 flux-2-dev 支持多参考图）暂不做；将来若需要，再加 `[providers.<p>.model_caps.<model>]` 子表。

## 解析优先级

默认模型：

1. `--model`
2. `<PROVIDER>_IMAGE_MODEL` 环境变量（逐家覆盖）
3. 本地缓存 `providers.<p>.default_model`（`--ref` 用 `default_ref_model`）
4. 脚本内置兜底（仅当缓存里缺这一家）

模型清单：缓存 `models`（种子/远端刷新）> 脚本 `PROVIDER_MODEL_LIST`（代码兜底）> 活的 API（`provider_<p>_models`，最后手段）。

Base URL：**不做逐家覆盖**（上游域名基本不变）。保留全局 `XGET_BASE_URL` 代理即可。

## 实现要点

### 种子 / 读取

```bash
registry.cache() { requests.cache.path "$IMAGINE_REGISTRY_URL"; }
registry.meta()  { printf '%s.meta' "$(registry.cache)"; }

# 前台：保证本地有数据，永不联网
registry.ensure() {
    local cache; cache="$(registry.cache)"
    [[ -s $cache ]] || registry.seed      # 内置兜底 → 原子写入缓存
    registry.refresh_background           # 仅判断是否过期，不等待
    return 0
}
```

- `registry.seed`：把适配器里的默认模型/静态清单渲染成与远端相同的 TOML，`tmp + mv` 原子写入；写个 `source=seed` 标记到 meta，便于识别。
- `registry.get <provider> <field>`：`core/config` loose 模式在子 shell 解析缓存（先清空再 load，避免污染运行时状态），缺值回退脚本兜底。

### 异步刷新

```bash
registry.refresh_background() {
    [[ -n ${IMAGINE_REGISTRY_OFF:-} ]] && return 0
    registry.is_fresh && return 0
    ( registry._refresh ) >> "$log" 2>&1 &   # 脱离父进程，不等待
    disown 2>/dev/null || true
    return 0
}

registry._refresh() {
    registry.lock || return 0              # mkdir 原子锁，超时可抢，避免并发重复拉取
    trap '...unlock...' EXIT
    registry.try_fetch || true             # 带 ETag 条件请求；无论成败都记录 attempt 时间
}
```

- **过期判定**：`IMAGINE_REGISTRY_TTL_HOURS`（默认 24）看独立标记 `<cache>.attempt` 的 mtime——**上次尝试回源的时间**，不是缓存内容时间。种子不写该标记，所以首次运行必拉一次远端；离线失败也会 touch，避免每次都重试。
- **锁**：`mkdir "$cache.lock"` 原子；已存在且未超时（如 5 分钟）就直接返回，避免并发进程重复拉。
- **原子替换**：`tmp + mv`；坏数据（缺 `[providers.`）丢弃并保留旧缓存。
- **失败隔离**：后台失败只落日志；前台已经用旧缓存/种子跑完了。
- 只在真正用到目录的命令里触发（生成、`providers`、`models`）；`--help`/`--version` 不触发。

### 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `IMAGINE_REGISTRY_URL` | 仓库 raw URL | 换源 |
| `IMAGINE_REGISTRY_TTL_HOURS` | 24 | 超过则后台刷新 |
| `IMAGINE_REGISTRY_OFF` | 空 | 设为 1 完全不回源（纯离线/调试） |

## 怎么更新

**用户**：什么都不用做。运行 `imagine` 时若缓存过期，后台自动刷新，下次运行生效。

**用户手动**：`imagine update` —— 同步强制刷新并打印变更摘要（默认模型变化、模型增删）。这是唯一会阻塞网络的操作，因为用户明确要求。

```
dashscope  default: qwen-image-plus → qwen-image-2.0-pro
           models: + qwen-image-3.0-pro
cloudflare models: + @cf/black-forest-labs/flux-2-dev
```

**维护者（更新全局数据）**：编辑 `registry.toml` 并提交。

- **手动更新是一等公民**：`registry.toml` 只是数据文件，手动改与脚本改等价；两者都建议走 PR，社区可提 PR 增删模型或改默认模型。
- `default_model` / `default_ref_model`：上游换代时人工确认；生成脚本不动这两个字段。
- `models`：可用 `scripts/update-registry.sh` 从活 API **合并**刷新（它只是逐个调 `imagine models <provider> --live`，复用适配器）；**只追加不删除**，人工条目不会被定时任务抹掉，删除靠手动 PR。缺凭证/无列表 API 的 provider 保留原值。
- 仓库带 `.github/workflows/update-registry.yml`：定时跑上面这个脚本并开 PR，人工确认后合入。
- 提交后用户端按 TTL 后台刷新，或 `imagine update` 立即拉取。

脚本与语言无关：它只调 CLI 的 `--live`，所以换成 TS/Python 也一样，但 Bash 在 CI 里零额外依赖。

## 影响面

- 新增依赖：`core/config`、`ext/requests`、`ext/requests.cache`（含 `std/path`）。载荷会涨，需要刷新 bashlet payload 基线。
- `provider.default_model` / `provider.default_ref_model` 读缓存；`provider.models` 为「缓存 models → 适配器静态 → 活 API」降级链。适配器里的兜底字段保留（作为种子来源）。
- 测试：种子写入、缓存读取、形状校验、异步刷新不改缓存、坏数据回退，用 stub 缓存 + 不联网。

## 迁移步骤

1. 建 `registry.toml` + `registry.seed`（内容 = 现在适配器里的默认模型 + 静态清单）；接 `provider.default_model`/`provider.models` 读缓存。
2. 接异步刷新 + 锁 + 形状校验。
3. 加 `imagine update`。
4. 补测试与文档，刷 payload 基线。

## 不做什么

- 不做逐 provider `BASE_URL` 覆盖（域名不变）。
- 不做每用户本地模型快照写回（会与全局数据分叉）。
- 前台不联网：任何情况下生成任务都不因目录刷新而变慢或失败。
- 能力声明不进目录（接口机制 ≠ 会变的数据）。
