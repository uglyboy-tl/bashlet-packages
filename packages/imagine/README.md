# imagine

命令行文生图 / 图生图工具，支持 8 家 provider。

## 用法

```bash
imagine --provider agnes -p "a red apple on a wooden table" -o out.png
imagine --provider google -p "..." --ar "16:9" -o out.png          # 按宽高比
imagine --provider dashscope -p "..." --ref ref.png -o out.png     # 参考图
imagine --provider dashscope models                                # 列出可用模型
```

## Provider 支持状态

实测日期 2026-10-04。

| provider | key 环境变量 | 实测 | 备注 |
| --- | --- | --- | --- |
| agnes | `AGNES_API_KEY` | 通过 | 全线模型免费 |
| google | `GOOGLE_API_KEY` | 通过 | |
| dashscope | `DASHSCOPE_API_KEY` | 通过（已修） | size 必须用星号 |
| minimax | `MINIMAX_API_KEY` | 通过 | 单次最多 9 张 |
| doubao | `ARK_API_KEY` | 通过 | |
| openrouter | `OPENROUTER_API_KEY` | 通过（已修） | 尺寸只能是固定集合 |
| openai | `OPENAI_API_KEY` | 未测 | 本地无 key |
| zai | `ZAI_API_KEY` | 未测 | 本地无 key |

## 接口备忘

各家接口对同一个概念的要求并不一致，以下三条是实际踩出来的。

### 尺寸格式不统一

- **dashscope**：`1024*768`（**星号**分隔）。传 `1024x768` 直接 400。
- **openrouter**：只接受 `1024x1024`、`1024x1536`、`1536x1024`、`auto`。传 `1024x768` 会被上游拒绝（错误信息含 `Invalid size`）。实现里按宽高比映射到前三者。
- **其余**（agnes / google / minimax / doubao / openai / zai）：`1024x768` 形式。

### 响应字段的坑

- **agnes**：URL 输出模式下 `b64_json` 返回的是**空字符串** `""`，而不是 `null`。jq 的 `//` 运算符只在 `null` / `false` 时回退，空串不触发，于是解析出空结果、误报 `No images in response`。解析必须显式排除空串再回退到 `url`。
- **其余**：未使用的字段为 `null`，`//` 回退行为正常。

### 速率与地区

- **agnes 免费层有速率限制**。连续发图时后续请求可能失败；隔一会儿重试即可。测试里两个生图用例连着跑时容易撞上，手动单跑则通过。
- **openrouter 对 OpenAI / Anthropic / Google 上游模型有账号级地区限制**，中国大陆 IP 可能收到地区不支持的错误。
  判据：看错误消息来自哪一层。若来自上游业务校验（如 `Invalid size`、模型参数错误），说明请求**已经到达**上游，问题在参数；若是地区 / 封禁错误，只能换 provider 或换非 OpenAI 模型。

### 超时

官方建议客户端超时 60-360s，当前实现为 `requests.timeout 120`。

## 测试

```bash
tools/test imagine          # 3 个离线用例 + 2 个真实生图（agnes 免费）
```

生图用例会真实调用 API。连续执行可能触发 agnes 免费层速率限制，导致后一个用例失败，重跑即可。
