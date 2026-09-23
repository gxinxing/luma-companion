# LumaCompanion 交接

## 当前状态

App 默认使用 Ricky 的付费 Apple Developer 团队 `YZYR3VWPA3`，Bundle ID 为 `com.rickyke.lumacompanion`，显示名仍为 **Luma**。Hotspot Configuration 已启用；“记忆”和“实时”会自动加入眼镜 Wi‑Fi。

Ricky iPhone 17 Pro 与星星 iPhone 15 Pro 均已登记到开发描述文件。开发签名有效期见 [`docs/INSTALL-ricky-signed.md`](docs/INSTALL-ricky-signed.md)。当前交付 IPA 的 SHA-256 为 `05ed4f4a33f46bb249d0c091af65c42998256c45099bc4b3db00da13f62b7533`。IPA、Rust 产物和验证截图均是仓库外产物，不提交 Git。

## 现场排障硬事实卡

| 项 | 现场事实 |
|---|---|
| 眼镜 | `E06-00F7`，BLE 固件 `1.4.9`。广播间歇出现，实测可能间隔 1–2 分钟，且广播包不带 AA12 服务标识；扫描必须保留名称回退，连接代码为此保留约五分钟重连窗口。 |
| GATT | 服务 AA12；写特征 AA13；控制通知 AA14；文件流 AA15。协议字节、URL 和定时以 sibling `../luma-core` 为权威来源。 |
| BLE 共用 | EyeVue 与 Luma 共用眼镜的 BLE 连接。联调前彻底退出 EyeVue，否则它可能占用连接。 |
| 签名 | Ricky 付费团队 `YZYR3VWPA3`，Bundle ID `com.rickyke.lumacompanion`；开发描述文件包含 Ricky iPhone 17 Pro `00008150-000919D436EA401C` 与星星 iPhone 15 Pro `00008130-001E35880A90001C`，有效期至 2027-09-24。 |
| 权限 | 蓝牙、本地网络和相册权限以 `project.yml` 的 `info` 为事实源；重跑 xcodegen 会据此生成 Info.plist。 |
| 热点 | 当前付费签名包含 Hotspot Configuration，“记忆”和“实时”自动加入眼镜 Wi-Fi，并在结束或失败后移除持久配置。免费个人团队不具备该权限，关闭对应 entitlement 与编译条件后走手动加入引导。 |
| 中台 | 公网地址 `https://ytd.rickyke.com`。设备页读取 `/api/snapshot` 的运行中 `runId`，再用用户填写的 Bearer 操作员令牌调用 `POST /api/stimuli`；令牌只保存在设备本机。 |
| 上报合同 | `{runId,id,source:{kind:"device",adapter:"glasses"},intensity}`；合成请求只能验证 HTTP 接缝，不能替代真实眼镜采集。 |

## 重建

先生成 Rust 核心和 UniFFI Swift binding：

```bash
brew install rustup
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
rustup default stable
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
cd ../luma-core && ./ios/build-core.sh
```

`project.yml` 改动后重新生成工程：

```bash
cd ../luma-companion
xcodegen
```

模拟器只用于编译和界面验证，蓝牙与热点流程必须在真机验证。

## 签名口径

付费团队默认配置：

- Team：`YZYR3VWPA3`
- Bundle ID：`com.rickyke.lumacompanion`
- entitlement：`com.apple.developer.networking.HotspotConfiguration`
- Swift 条件：`HOTSPOT_CONFIGURATION`

免费个人团队也能运行，但不支持 Hotspot Configuration。切换到免费团队时，必须同时删除 entitlement key 和 `HOTSPOT_CONFIGURATION` 编译条件；App 随后显示 SSID 与密码，引导用户手动加入。热点流程只有一套实现，编译条件只决定由 App 自动应用配置还是等待手动加入。

## 蜂群中台

设备页从 `/api/snapshot` 获取运行中的 `runId`，再向 `/api/stimuli` 发送：

```json
{
  "runId": "…",
  "id": "…",
  "source": { "kind": "device", "adapter": "glasses" },
  "intensity": 0.5
}
```

操作员令牌由用户在设备页填写，只保存在本机 UserDefaults。仓库、Info.plist、日志和截图中不得保存令牌。HTTP 接缝可用 `TOKEN=<令牌> ./verify-swarm.sh <中台地址>` 验证；这只能证明 HTTP 合同，不能替代眼镜 BLE 端到端验证。

## 已知边界

- 眼镜 BLE 广播可能间歇出现，连接代码按名称回退并保留约五分钟重连窗口。
- EyeVue 会占用同一条 BLE 连接，测试前应退出。
- 没有眼镜时，本地相册只能用于查看历史捕获，不能作为 `device/glasses` 刺激上传。
- 真实眼镜 BLE、拍照、RTSP 和眼镜热点端到端状态必须在交付记录中单独说明，不能由模拟器或合成图片替代。
