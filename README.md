# AwakeKit

一款简单高效的 macOS 菜单栏防休眠工具，让你的 Mac 保持清醒。

AwakeKit 通过 IOKit 电源断言（power assertion）阻止系统进入空闲休眠，支持定时自动结束、接通电源时的增强防休眠、登录时启动与状态通知，无需常驻后台守护进程。

## 下载安装

前往 [Releases 最新版](https://github.com/peninsulagiftbox/AwakeKit/releases/latest) 下载 `AwakeKit-<版本号>.dmg`，打开后将 AwakeKit 拖入 Applications 文件夹即可完成安装。

所有历史版本均保留在 [Releases 列表](https://github.com/peninsulagiftbox/AwakeKit/releases) 中，需要回退旧版本时按版本号下载对应的 DMG 即可。

> 安装包使用 ad-hoc 签名。首次打开若提示"无法验证开发者"，请右键 App 选择"打开"，或前往 系统设置 → 隐私与安全性 点击"仍要打开"。

## 功能

- **一键保持唤醒**：从菜单栏面板开启/关闭，支持 15 / 30 / 45 分钟、1 / 4 / 8 小时和一直保持，剩余时间实时倒计时显示。
- **增强防休眠**（可选，仅接通电源时生效）：额外请求系统级防休眠断言，防止长时间无操作导致的系统睡眠；使用电池供电时自动释放。
- **登录时启动**：基于 SMAppService（macOS 13+）注册登录项，无需手写 plist。
- **状态通知**：开始/停止保持唤醒时发送系统通知，可关闭。
- **设置持久化**：默认持续时间等偏好自动保存。

实现上优先使用 `IOPMAssertionCreateWithName` 创建防休眠断言；当 IOKit 断言创建失败时自动回退到 `caffeinate` 辅助进程（带 `-w` 绑定宿主进程 PID，应用意外退出时不会遗留孤儿断言）。

## 环境要求

- macOS 13.0 或更高版本
- Xcode 命令行工具（Swift 6.4 工具链）

## 构建

```bash
# 直接构建可执行文件
swift build

# 组装 AwakeKit.app（含图标、Info.plist 与 ad-hoc 签名），输出到 dist/
Scripts/make-app.sh

# 制作 DMG 安装镜像（输出 dist/AwakeKit-<版本号>.dmg）
Scripts/make-dmg.sh

# 运行测试
swift test
```

> 提示：登录时启动、状态通知等功能需要通过 `Scripts/make-app.sh` 组装的 `.app` 包运行；直接运行 `.build` 下的裸可执行文件时这些功能不可用。

## 许可证

[MIT](LICENSE)
