# LumaCompanion 交接

## 当前状态

App 默认使用 Ricky 的付费 Apple Developer 团队 `YZYR3VWPA3`，Bundle ID 为 `com.rickyke.lumacompanion`，显示名仍为 **Luma**。Hotspot Configuration 已启用；“记忆”和“实时”会自动加入眼镜 Wi‑Fi。

Ricky iPhone 17 Pro 与星星 iPhone 15 Pro 均已登记到开发描述文件。开发签名有效期见 [`docs/INSTALL-ricky-signed.md`](docs/INSTALL-ricky-signed.md)。IPA、Rust 产物和验证截图均是仓库外产物，不提交 Git。

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
