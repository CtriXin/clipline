# 上游 fork 调研（2026-10-10）

上游 alejandrobujan/tendedero 共 109 个 fork，18 个 main 有新提交，另有若干只在分支上。以下按对 Clipline 的参考价值排序。全部基于 MIT 源码；借鉴时保留署名，不用他们的名字和图标。

## 值得借鉴（优先级从高到低）

| 来源 | 内容 | 对我们的意义 |
|---|---|---|
| y0un922/tendedero | 监听 `~/Library/Containers/com.tencent.qq/Data/tmp` 里的 `QQ_*.png`（跳过 `_thumb`）；空格键 Quick Look 预览；绳子被 macOS 停到别的 Space 时拉回来 | 国内截图工具常只进剪贴板/私有目录；Quick Look 比我们的悬停预览多了缩放 |
| 上游 PR #42（orkunisitmak，基于 Anubhav-Rai PR #1） | 剪贴板图片上绳，带隐私检查和合成测试，默认关闭 | 与我们的 ClipboardWatcher 同方向，可对照补测试 |
| 上游 PR #24（Anubhav-Rai） | 绳子收起时把窗口 order out | 省资源，避免收起时还拦鼠标 |
| 上游 PR #49 / #51 / #22 | 下拉时带到当前 Space；截图文件未写完时重试；watcher 不阻塞启动 | 都是稳定性小修，可直接合 |
| yoshiyms/tendedero | 菜单栏边缘检测改用 `NSMouseInRect` | 多屏/刘海屏触发更准 |
| crisp-toast、wakeupbrk/pegline | 从任意 app 拖图片/文件到绳上（挂临时副本） | 与我们「全部临时」的定位一致 |
| blastermars/sinampay | 剪贴板历史；卡片沿绳自由滑动 + 一键整理；绳子下落速度可调 | 交互细节参考 |
| constZinovyev（constzin/line-tweaks，+34） | 卡片沿绳移动、预览可拖拽缩放、清空前确认、每日备份；彩灯/蜡烛/锁屏等实验 | 预览可缩放值得学；备份与我们「不保留」相反，不采用 |
| ukccatc/hangrail、GausPeerzade/pinwire、z333d/pinloom | 钉住/归档、剪贴板便签、待办与网页卡片 | 方向参考，「钉住不掉落」可能有用 |
| ironxc/tendedero | 取色、标记、固定等截图增强（中文） | 可看取色实现 |

## 其他平台

- **Windows**：The-Coaxys/tendedero 分支 `add-windows-port`（上游 PR #41，未合并）。Rust + Win32 原生，`windows/` 目录约 3.5k 行，监听截图目录、WIC 解码、剪贴板拖拽、NSIS 安装包，已在 Windows 11 验证；已发布 `windows-v1.0.0`（Setup.exe + portable.exe）。**没有剪贴板上绳**，名字和图标仍是 Tendedero。
- **Linux**：pnaaberi/tendedero 分支 `linux-pegline`（Pegline），Rust 核心 + Qt6，KDE Wayland，含剪贴板。
