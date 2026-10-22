# FinderOpenInIterm

在 Finder 里按住 `⌘ + Option` 双击文件夹 → 新开一个 iTerm2 窗口并直接执行 `cd -- '/该文件夹'`。

- 图标、文件夹名、列表/分栏/图标视图都支持
- 点空白处、点文件不会触发
- 路径含空格、单引号、双引号都安全（shell 转义）

## 文件

| 路径 | 说明 |
| --- | --- |
| `~/Applications/FinderOpenInIterm.app` | 实际运行的程序 |
| `~/Library/LaunchAgents/local.tangguorong.FinderOpenInIterm.plist` | 开机自启 |
| `~/Library/Logs/FinderOpenInIterm.log` | 运行日志 |

## 改代码

```bash
./build.sh
launchctl bootout gui/$(id -u)/local.tangguorong.FinderOpenInIterm
cp -R build/FinderOpenInIterm.app ~/Applications/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.tangguorong.FinderOpenInIterm.plist
```

### 重新编译后必须重新授权

程序是 ad-hoc 签名的，二进制一变，macOS 就把它当成另一个 app，辅助功能授权作废。
重新编译后执行：

```bash
tccutil reset Accessibility local.tangguorong.FinderOpenInIterm
```

然后重启进程，在 系统设置 › 隐私与安全性 › 辅助功能 里把 FinderOpenInIterm 重新打开。

## 卸载

```bash
launchctl bootout gui/$(id -u)/local.tangguorong.FinderOpenInIterm
rm -rf ~/Applications/FinderOpenInIterm.app \
       ~/Library/LaunchAgents/local.tangguorong.FinderOpenInIterm.plist \
       ~/Library/Logs/FinderOpenInIterm.log
tccutil reset Accessibility local.tangguorong.FinderOpenInIterm
```

## 实现要点

- 全局 `leftMouseDown` 事件拦截（`CGEventTap`，需要辅助功能权限），命中「⌘+Option+双击 且 Finder 在前台」才消费事件
- **回调里绝不做跨进程查询**：只读事件字段和一个缓存的 Bool，微秒级返回；查 AX、跑 AppleScript 全部丢到后台队列。这是之前导致整机卡死的原因，改动时务必保持
- 通过 AX 命中元素向上找 `AXURL`；Finder 给的是 `file:///.file/id=...` 引用式 URL，用 `NSURL.filePathURL` 转真实路径
- 图标视图点文件夹名时命中的是空的图标容器，用「图标下方 56pt 属于标签区」的几何匹配兜底，带 600 节点 / 200ms 预算
- 单次 AX 调用 0.2s 超时；二次点击被吞掉，Finder 不会同时打开自己的窗口
- 保险丝：60 秒内事件回调超时 3 次就自动停用拦截并写 `FATAL` 日志

