# apthist

分析 apt/dpkg 日志，列出最近 N 天安装或卸载的软件包。默认只显示当前仍然安装、且是手动安装的包。

## 用法

```bash
apthist                  # 最近 7 天安装的手动包
apthist -d 14 -a         # 最近 14 天安装的所有包（含自动安装）
apthist -d 7 -r          # 最近 7 天卸载的包
apthist -l /var/log/apt/history.log.1   # 指定日志文件，覆盖多源探测
```

| 选项 | 说明 |
| --- | --- |
| `-d, --days DAYS` | 分析最近多少天的记录（默认 7） |
| `-l, --log FILE` | apt 日志文件路径（指定时覆盖多源探测） |
| `-a, --auto` | 显示自动安装的包 |
| `-r, --removed` | 显示已卸载的包 |

数据源是 `/var/log/apt/history.log`（含轮转，`.gz` 用 `gzip -dc` 读）；缺失时回退 `/var/log/dpkg.log`，
后者没有自动安装标记，会先警告一行。读 `dpkg.log` 需要 root，权限不足时提示 `试试 sudo`。

包的状态由安装/卸载序列推导，后出现的动作覆盖前者；输出按日期升序，左栏宽度按最长包名动态对齐。
非法 `--days`（如 `-d abc`）回退默认值而不是报错。

## 开发

```bash
tools/test apthist    # 6 条用例
tools/build apthist   # 产出 packages/apthist/build/apthist
```
