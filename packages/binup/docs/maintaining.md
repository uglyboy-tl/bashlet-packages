# 扩充包目录的流程

写给维护者：怎么找候选、怎么验证、哪些文件进仓库、哪些只是本地原料。

`registry.toml` 是唯一的权威定义，本目录的 `catalog.md` 是它的人读版分类索引。

## 文件归属

| 路径 | 进仓库 | 作用 |
| --- | --- | --- |
| `registry.toml` | ✅ | 权威包定义（binup 默认从远端 raw 地址拉它） |
| `docs/catalog.md` | ✅ | 人读版分类索引，与 `registry.toml` 同步 |
| `docs/candidates.md` | ✅ | 候选池：判据、待入库清单、已剔除记录 |
| `scripts/binup-check.sh` | ✅ | 候选验证脚本（浅层 / `--deep`） |
| `downloads/` | ❌ | `binup upgrade` 的归档缓存（默认 `download_dir`） |
| `scratch/` | ❌ | 采集原料：期刊原文、索引 TSV、批量验证输出 |

`scratch/` 是纯本地目录，里面的东西都能按下面的命令重新生成，所以不占仓库体积。

## 采集来源

**HelloGitHub 期刊**（每月 28 号发，第 N 期对应 2023-01 起的第 N-82 个月）：

```bash
gh api repos/521xueweihan/HelloGitHub/contents/content/HelloGitHub<N>.md \
  --jq '.content' | tr -d '\n' | base64 -d > scratch/HG<N>.md
```

**x-cmd 包索引**（curated 索引，每天 12:00 UTC 重建成 release）：

```bash
gh release download --repo x-cmd/install --pattern 'v1.all.tsv' --dir scratch/
# 列：name / category / lang / source / desc_cn / desc_en / binlist / rule / other
# 只有走 `x eget`（从 GitHub release 装预编译二进制）的那部分才是候选
```

## 一轮扩充

1. **采集** —— 落到 `scratch/`
2. **去重** —— 与 `registry.toml` 的 `repo` 字段、`candidates.md` 的已剔除表比对
3. **验证** —— `scripts/binup-check.sh <owner/repo>...`；先浅层筛模板一致性，再对存活的加 `--deep`
4. **筛选** —— 按 `candidates.md` 的入库判据砍
5. **入库** —— 写进 `registry.toml`（按包名字母序插入，不再分节）
6. **同步** —— 同样的条目加进 `docs/catalog.md` 的对应分类
7. **回归** —— `tools/test binup`；再校验语法与条目数（tomllib 需 Python 3.11+）：

   ```bash
   python3 -c "import tomllib; print(len(tomllib.load(open('packages/binup/registry.toml','rb'))['packages']))"
   ```

收录门槛（单文件可执行、几个各自独立的二进制、单文件压缩包必须配 `binary_name`）见 [`../README.md`](../README.md)，此处不重复。

## 重排 registry

`registry.toml` 只按包名字母序排（用途分类只在 `docs/catalog.md` 维护）。新增几批后要重排时跑：

```bash
python3 - << 'PY'
import re, pathlib
p = pathlib.Path('packages/binup/registry.toml')
lines = p.read_text().split('\n')
i = next(n for n, l in enumerate(lines) if l.startswith('[packages.'))
head, blocks, cur = lines[:i], [], None
for l in lines[i:]:
    if l.startswith('[packages.'):
        if cur: blocks.append(cur)
        cur = [l]
    elif cur is not None:
        cur.append(l)
if cur: blocks.append(cur)
# 按包名排序而不是整行：否则 `[packages.hugo-extended]` 的 `-` 会排到 `[packages.hugo]` 前面
blocks.sort(key=lambda b: re.match(r'^\[packages\.(.+)\]$', b[0]).group(1).lower())
p.write_text('\n'.join(head).rstrip() + '\n\n'
             + '\n\n'.join('\n'.join(b).strip('\n') for b in blocks) + '\n')
PY
```

排序不碰文件头说明，也不改任何字段，只搬整块；排完用 `tools/test binup` 确认。

## 验证脚本

```bash
# 浅层：只比两侧资产模板是否一致，不下载（快，用于大批量初筛）
scripts/binup-check.sh owner/repo owner/repo2

# 深度：真下载解压，列出会被装进去的文件，并跑一次 --version
scripts/binup-check.sh --deep owner/repo
```

`--deep` 只跑宿主架构那一侧。脚本反推出的 `file_pattern` 落地前要人工核对一遍，
带日期或平台后缀不规则的（如 `N_m3u8DL-RE` 的 `_20260629`）尤其要看。

## 踩过的坑

| 现象 | 原因 |
| --- | --- |
| 选中了 `.dmg` / `.AppImage` / `.deb` | 非 Linux 可执行包混进候选，且文件名更短 |
| 选中了 `.sha256` / `.sig` / `.pem` / `.yml` | sidecar 文件被当成资产 |
| 安装脚本混进候选（`uv-installer.sh`、`atuin-installer.sh`、`deps_linux.sh`） | 排除表挡了 `.deb` / `.rpm` 一类，却没挡 `.sh` / `.py` 等脚本，名字带架构标记的安装器还可能被选为预期资产 |
| `mac-` / `ios` / `android` 变体混进来 | 平台排除表只写了 `darwin` / `macos` / `osx` 这类全称 |
| `.AppImage` 没被排除 | 排除表按小写匹配，大写后缀漏网 |
| 装出 `dirsearch-0` / `dbmate-2` 这种名字 | 裸二进制没配 `binary_name`，binup 截到第一个点之前 |
| `.gz` / `.bz2` / `.xz` 单文件包装不进去 | 单文件压缩包必须配 `binary_name` |
| `--version` 退出码 ≥ 126 | 缺系统库，不是包的问题 |
| 解压后多个文件互相覆盖 | 多平台合一包，或编辑器 runtime 兄弟目录（neovim / helix） |
| `binup update` 每个包都报「获取版本失败」 | `file_pattern` 结尾带了扩展名，与 `file_extension` 叠加成 `…tar.gz[.][^.]*tar.gz$`，永远匹配不到 |

这些都已修进 `scripts/binup-check.sh`，改脚本时别把对应的过滤条件删掉。
