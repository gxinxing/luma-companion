# LumaCompanion — 眼镜的 iPhone 伴侣 App（V1）

第一视角 AI 记录工具：打开 App 自动连上眼镜（`E06-00F7`），拍下你看见的，
在「记忆」里查看、下载、分享、删除。工程由 [`../eyevue-audit/报告.md`](../eyevue-audit/报告.md)
的逆向结论驱动 —— 那里记录了原厂 App 的结构与本 App 刻意修正的连接 UX 问题。

## 是什么

- **四个 tab**：拍摄（状态+电量+大快门+最近拍摄卡片+最近 AI 预览）、实时（RTSP 取景器）、
  记忆（眼镜相册：浏览/下载/分享/删除）、设备（电量/固件/设置快照/断开/蜂群中台上传）。
- **最近拍摄卡片**：右滑保存到 iOS 相册（需允许「添加到相册」权限），左滑删除；触觉反馈。
- **蜂群中台上传**：拍摄画面按 glasses-stimulus/v1 合同语义提取本机特征（32×32 下采样、
  Rec.709 亮度、HSL 色相桶、Sobel 边缘密度、8×8 aHash），强度 = 0.5·亮度 + 0.3·边缘密度 +
  0.2·饱和度（与 src/glasses-music-stimulus.mjs 的 INTENSITY_WEIGHTS 一致），POST /api/stimuli
  送进演出（runId 自动从 /api/snapshot 发现，操作员令牌在设备页配置）。
  接口预检可运行 `TOKEN=<操作员令牌> ./verify-swarm.sh [中台地址]`。脚本在 2026-09-24
  对本地真实 aria-swarm 服务验证了 200 → `music.stimuli` 回查命中，也验证无运行场次时
  返回非零；它发送的是合成 HTTP 设备刺激，仍需用眼镜新拍照片做真机验收。
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
- **眼镜 Wi-Fi 需手动加入（免费账户限制）**：免费个人团队**不支持 Hotspot
  Configuration 权限**（已从 entitlements 移除该 key），因此「记忆」/「实时」首次
  使用时按 App 屏幕提示到 设置▸Wi-Fi 手动加入眼镜网络（屏幕会显示 SSID+密码），
  一次性——之后 iOS 自动关联。付费开发者账号可恢复 entitlement 走全自动流程。
- 首次运行 iOS 会弹蓝牙与本地网络权限。
- 与原厂 EyeVue 共用一条 BLE 连接：测试前把 EyeVue 的连接断开（或蓝牙关掉）。

## 目录

```
LumaCompanion/
├── LumaCompanionApp.swift          # 入口 + 四 tab
├── Services/
│   ├── GlassesLink.swift           # 重写：名字回退发现 + Phase 状态机 + 自动重连
│   │                                #   + AA15 文件流（AI 小图 → lastCapture）
│   ├── GlassesWiFi.swift           # ↓ 以下四个与 LumaDemo 逐字节一致（已验证的管线）
│   ├── FileApiClient.swift
│   ├── LiveStreamSession.swift
│   └── LiveAudioPlayer.swift
├── Features/
│   ├── Capture/CaptureView.swift   # 拍摄：取景器 + 快门 + StatusPill
│   ├── Live/LiveScreen.swift       # 实时：复用 demo 视频层，去掉教学清单
│   ├── Memories/MemoriesScreen.swift # 记忆：分组网格 + 查看器 + 下载/分享/删除
│   └── Device/DeviceView.swift     # 设备：只读信息 + 断开
└── Support/Theme.swift             # 深色 first-person recorder 主题 + StatusPill
```

## 验证状态（诚实边界）

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
- 本目录不是 git 仓库（工作区约定：`luma-core` 才是上游 SDK 仓库）。

## 给下一个 agent

- **先读 [`HANDOFF.md`](./HANDOFF.md)** —— 最新状态、重建命令、待办清单、令牌排查结论、已踩坑清单都在那里。
- 改连接行为 → `Services/GlassesLink.swift`（读文件头注释，那里有本机广播怪癖的来龙去脉）。
- 改 UI → `Features/`，状态一律从 `link.phase` 派生，别自己另存一份连接状态。
- 协议疑问 → `../luma-core/PROTOCOL.md`（字节级）与 `docs/GUIDE.md`（流程级）。
- 原厂 App 对照 → `../eyevue-audit/报告.md`。
