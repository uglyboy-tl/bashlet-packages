# config.update 全局匹配 Bug

## 症状

向不存在的 section 追加新 key 时，`config.update` 会全局搜索该 key 名并误替换已有值，然后提前返回，整个新 section 不追加。

## 复现条件

配置文件中有如下内容：

```toml
[sources.guizang-social-card-skill]
repo = "op7418/guizang-social-card-skill"

[agents.opencode]
user_dir = "~/.config/opencode/skills"
```

调用：

```bash
config.update "sources" "NEW" "repo" "owner/repo" config.toml
```

预期：在文件末尾追加 `[sources.NEW] repo = "owner/repo"`。

实际：找到文件第一个 `^repo[[:space:]]*=`（`guizang-social-card-skill` 那行），替换为 `repo = "owner/repo"`，然后 return。新 section 丢失，旧 section 被破坏。

## 根因

`config.update` 第 139 行：

```bash
[[ -n $_sec ]] && _n=$(fs.find "$_f" "^${_sec_grep}$") || _n="" && fs.find "$_f" "$_pat" "$_n" 1> /dev/null && fs.replace "$_f" "$_pat" "$_repl" "$_n" && return 0 || true
```

当 section 头找不到时，`_n` 为空。`&&`/`||` 优先级相同、左结合：

1. `[[ -n $_sec ]]` → true (section 非空)
2. `_n=$(fs.find ...)` → 未找到，`_n=""`，exit 1
3. `|| _n=""` → 执行（空赋值，exit 0）
4. `fs.find "$_f" "$_pat" ""` → 从第 1 行开始**全局**搜索 key 模式
5. 在错误的位置匹配到同名的 key → `fs.replace` 误替换 → `return 0` 提前退出

## 影响范围

- 所有 `config.update` 首次向不存在的 section 追加 key 的调用
- binup 仅因 `^latest_version[[:space:]]*=` 不会误匹配其他 section 才未暴露（罕见先有全局 latest_version 的情况会触发）

## 已采用的替代方案

SkillInk 中改用 `config.array.set + config.save`：

```bash
config.array.set sources "$name" repo "$repo"
config.save "$(config.path)"
```

`config.array.set` 更新内存，`config.save` 完整重写全部已注册配置到文件。缺点：会丢失文件中未注册的自定义 key。
