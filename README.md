# LumaCompanion — 眼镜的 iPhone 伴侣 App（V1）

第一视角 AI 记录工具：打开 App 自动连上眼镜（`E06-00F7`），拍下你看见的，
在「记忆」里查看、分享、保存、删除蓝牙回传的小图。工程由 [`../eyevue-audit/报告.md`](../eyevue-audit/报告.md)
的逆向结论驱动 —— 那里记录了原厂 App 的结构与本 App 刻意修正的连接 UX 问题。

## 是什么

- **三个 tab**：感知（BLE 拍摄、连接状态、最近一帧）、记忆（手机本地的 BLE 拍摄预览：查看/分享/存相册/删除）、蜂群（真实运行快照、Jev/蜂群/音乐证据、照片上报及设备详情）。
- **主动感知的证据边界**：蜂群页读取 `/api/snapshot` 的本轮模型调用、判断、已应用蜂、音乐痕迹、乐句代际和设备来源；缺失指标显示「—」。当前拍照由人触发，持续自主采集、语音和 SECTION 9 任务层未在手机端实现。
- **无眼镜热点**：当前导航不启动 Wi-Fi、RTSP 或眼镜文件 API。连续实时视频和眼镜内完整相册需要热点，暂不在手机动线中提供；记忆页显示的是 BLE 回传小图。
- **最近拍摄卡片**：右滑保存到 iOS 相册（需允许「添加到相册」权限），左滑删除；触觉反馈。
- **Jev 眼镜 Agent**：从 BLE 照片本机提取亮度、边缘密度、饱和度，POST
  `/api/glasses-agent/observe`；Jev 决定是否值得通知蜂群以及刺激强度，不上传原始照片，
  不由手机预设音乐改动。runId 自动从 `/api/snapshot` 发现。客户端已接上该合同，
  但截至 2026-09-24 09:47，线上站点该路径仍返回 401，PR #54 尚未合入/部署，
  所以当前不能宣称眼镜到生产音乐的端到端完成。PR 部署后无需设备操作员令牌。
- **协议零硬编码**：所有字节、URL、定时都来自 `luma-core` 的 Rust 核心
  （经 UniFFI 生成的 Swift binding，`import LumaCore`）。
- **与 LumaDemo 的关键差异**：
  1. **名字回退发现**：本机眼镜不在 BLE 广播里带 `AA12`，demo 的服务过滤扫描永远
     扫不到它（2026-09-22 经 Python 连接器实测）。这里扫描不过滤、按名字/服务匹配、
     连接后用 `glassesIsDrivable` 校验 GATT 表。
  2. **显式连接状态机**（`Phase`）：扫描/连接/握手/已连接/失败全程可见可解释，
     替代 demo 的字符串 phase；失败给出原因而非静默。
  3. **自动连接 + 时间窗口重连**：启动即连（记住上次设备）；意外掉线后在约 5 分钟窗口内
     （30 轮 × 10 秒）持续但温和地寻找，期间 UI 一直显示「正在寻找眼镜…」，扫到/连上立即
     恢复；窗口用尽才停在可解释的失败态（眼镜 BLE 广播间歇性，实测 1-2 分钟才广播一轮，
     演示现场不能 5 次就放弃）。原厂 App 的静默重连环是逆向报告 §5 的头号问题。
  4. **AI 小图回传**：`AA15` 走 `GlassesFileReassembler`，`take_photo(ai)` 的小 JPEG
     直接落在拍摄页的取景器里。
- **V1 明确不做**（与既定方向一致）：账号/云同步、社区、剪辑、翻译/传译/通话、
  AI 语音闭环（眼镜 Opus → STT → TTS 留 V2）、设置写入。

## 怎么跑

## 当前交付状态（2026-09-24）

- aria-swarm 最新 `origin/main` 已快进到 `b67ce67`；公网 `https://ytd.rickyke.com`
  健康检查正常，快照显示演出运行中、Jev 决策和实际音符改动在发生，设备刺激计数为 0。
- 手机端改为将本机图像特征交给 Jev 眼镜 Agent，并按 Agent 的 `willSignal` 结果显示
  已触发或场景无需打扰。iOS 应用代码已调用 `/api/glasses-agent/observe`；该端点在
  aria-swarm PR #54 中，生产站点尚未部署。手机真机 BLE 与生产 E2E 还未实测。
- 本轮 Swift 源码修改已于 09:50 通过 `xcodebuild -scheme LumaCompanion -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`；这是无签名编译，不是装机或真机 E2E。项目状态和下一步见
  [`../PROJECT_CONTEXT.md`](../PROJECT_CONTEXT.md)。

前置（一次性）：

```bash
# 1. Rust iOS 切片 + Swift binding（产物 gitignored，必须先跑）
#    需要 rustup：brew install rustup && export PATH=/opt/homebrew/opt/rustup/bin:$PATH
#    然后：rustup target add aarch64-apple-ios aarch64-apple-ios-sim
cd "../luma-core" && ./ios/build-core.sh

# 2. 生成工程（仅当 project.yml 有改动时）
cd ../luma-companion && xcodegen
```

日常：

```bash
open LumaCompanion.xcodeproj   # Xcode 里选真机 iPhone 运行
```

- **必须真机**：模拟器没有蓝牙/热点。模拟器只能编译看 UI。
- **真机构建要求**：Xcode 登录 Apple ID（免费个人团队即可）；**团队 ID 是
  `2TTT5WBW7Y`**（已写入 project.yml；免费账户第一次 Run 时 Xcode 自动注册 App ID、
  创建描述文件）。
- 当前三页动线无需加入眼镜 Wi-Fi。场馆笔记本上的蜂群中台若使用局域网地址，手机仍需接入与笔记本相同的常规网络。
- 首次运行 iOS 会弹蓝牙与本地网络权限。
- 与原厂 EyeVue 共用一条 BLE 连接：测试前把 EyeVue 的连接断开（或蓝牙关掉）。

## 目录

```
LumaCompanion/
├── LumaCompanionApp.swift          # 入口 + 感知 / 记忆 / 蜂群
├── Services/
│   ├── GlassesLink.swift           # 重写：名字回退发现 + Phase 状态机 + 自动重连
│   │                                #   + AA15 文件流（AI 小图 → lastCapture）
│   ├── GlassesWiFi.swift           # 历史热点实现，当前导航不调用
│   ├── FileApiClient.swift
│   ├── LiveStreamSession.swift
│   └── LiveAudioPlayer.swift
├── Features/
│   ├── Capture/CaptureView.swift   # 拍摄：取景器 + 快门 + StatusPill
│   ├── Live/LiveScreen.swift       # 历史实时实现，当前导航不调用
│   ├── Memories/LocalMemoriesScreen.swift # 当前记忆页：本地 BLE 小图
│   ├── Memories/MemoriesScreen.swift # 历史眼镜热点相册，当前导航不调用
│   └── Device/DeviceView.swift     # 蜂群：真实快照 + 上报 + 设备详情
└── Support/Theme.swift             # 深色 first-person recorder 主题 + StatusPill
```

## 验证状态（诚实边界）

- 2026-09-24 09:35：三页 UI 已按眼镜→感知→Jev→音乐的因果顺序重排；蜂群页在模拟器中成功读取生产快照并显示真实本轮指标（当时 modelCalls=28、decisions=28、appliedBees=6、music.traces=2、device 未接入）。模拟器人工检查感知、记忆空态、蜂群首屏和中台输入区，底部输入可滚动到可操作区域；主屏图标已显示。拍照命令新增 15 秒回传超时和明确失败状态。图标为深色底的简洁 L 字标，Xcode 资源目录 `Assets.xcassets/AppIcon.appiconset` 已接入。Simulator 与签名设备构建均 **BUILD SUCCEEDED**；签名包为 `/tmp/lumacompanion-dd-signed/Build/Products/Debug-iphoneos/LumaCompanion.app`（版本 3、Team ID `2TTT5WBW7Y`、AppIcon 已入 Info.plist）。iPhone 在 `devicectl` 中仍是 unavailable，未装机或真机联调。

- 2026-09-24 09:19：按用户「不要连热点」要求，当前导航改为拍摄/本地记忆/设备三页；记忆页直接读取 `CaptureStore`，不触发 `glassesOpenWifi`，支持刷新、查看、分享、保存系统相册和删除。`xcodegen` 已重跑；iOS device 和 Simulator 两套目标无签名 **BUILD SUCCEEDED**；模拟器已安装启动，人工点击「记忆」确认空态与三 tab 正常显示。签名设备构建也 **BUILD SUCCEEDED**，可装包位于 `/tmp/lumacompanion-dd-signed/Build/Products/Debug-iphoneos/LumaCompanion.app`，版本号 2、Team ID `2TTT5WBW7Y`、ATS 本地网络许可均核实。iPhone 当前仍为 unavailable，真机安装、BLE 拍照、相册保存与上传尚待验收。

- 2026-09-24 09:02：重新运行 `xcodegen` 与无签名 iOS device 目标构建；修复记忆页本地相册兜底的 `private(set)` 写入和图片视图参数编译错误后，`xcodebuild -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` **BUILD SUCCEEDED**（包含 ATS 配置、SPM 本地包解析与链接）。iPhone 15 Pro 目前在 `devicectl` 中为 unavailable；本轮尚未签名、装机或做眼镜端到端验证。构建日志：`/tmp/lumacompanion-build-20260924.log`。

- 2026-09-24 02:45：**提交前冲刺轮——31 项审计修复完成**（双线审计 38 项发现；崩溃级 5、演示主链路 9、交互/数据 17；另有 7 项有据不修）。构建与部署：
  - iOS Simulator（iPhone 17 / iOS 26.5）：`xcodebuild … build` → **BUILD SUCCEEDED**，安装+启动+截图确认 UI 正常渲染
  - iOS 真机（iPhone 15 Pro，team 2TTT5WBW7Y）：签名构建 **BUILD SUCCEEDED**，已 `devicectl` 安装（解锁点图标即启动）
  - **当前完整交接见 [`HANDOFF.md`](./HANDOFF.md)**（重建命令、令牌排查、待办、代码地图、坑清单——接手前必读）
- 2026-09-23：**完整 Xcode 构建双平台通过**——
  - iOS Simulator（arm64，iOS 26.5 runtime）：`xcodebuild -scheme LumaCompanion -destination 'generic/platform=iOS Simulator' build` → **BUILD SUCCEEDED**
  - iOS 真机（arm64，无签名验证构建）：`-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**
  - 含 SPM 解析（LumaCore 本地包）与 Rust 静态库（`-lluma_core`）真实链接。
  - 全部源码另经 `swiftc -typecheck` 单独验证（10 个源文件 + 真实生成 binding）。
- 构建本机曾缺 iOS 平台组件：已用 `xcodebuild -downloadPlatform iOS` 装上 iOS 26.5
  模拟器 runtime（8.52 GB）。**新建源文件后必须重跑 `xcodegen`**，否则文件不进工程
  （CaptureStore.swift 首次构建因此失败过一次）。
- 真机 BLE/热点/RTSP **仍未端到端实测**（模拟器无蓝牙硬件；02:45 前的修复轮基于静态审计 +
  构建验证）。眼镜下次开机后按 HANDOFF §5 清单实测：自动连接、拍照回传、卡片滑动、
  实时复播、记忆热点流程、断连重连窗口。
- 已知简化：下载暂无进度条（文件小、走眼镜热点）。
- 本目录是独立 Git 仓库 `gxinxing/luma-companion`；`luma-core` 是旁边的 SDK 仓库。

## 给下一个 agent

- **先读 [`../PROJECT_CONTEXT.md`](../PROJECT_CONTEXT.md) 和本 README 最新验证条目**。`HANDOFF.md` 保存此前四页/热点方案的历史交接，不能当成当前导航状态。
- 改连接行为 → `Services/GlassesLink.swift`（读文件头注释，那里有本机广播怪癖的来龙去脉）。
- 改 UI → `Features/`，状态一律从 `link.phase` 派生，别自己另存一份连接状态。
- 协议疑问 → `../luma-core/PROTOCOL.md`（字节级）与 `docs/GUIDE.md`（流程级）。
- 原厂 App 对照 → `../eyevue-audit/报告.md`。
