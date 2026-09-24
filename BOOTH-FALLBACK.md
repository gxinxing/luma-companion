# 现场降级方案（眼镜 → 中台那条链路）

建立时间：2026-09-24 03:40 Asia/Shanghai
事实源：[`../PROJECT_CONTEXT.md`](../PROJECT_CONTEXT.md)；App 侧细节见 [`HANDOFF.md`](./HANDOFF.md)

## 一句话

眼镜到蜂群中台的唯一缺口是**生产操作员令牌**（在 Ricky 服务器的 `/opt/aria-swarm/.env` 里，本机无副本）。
令牌拿不到也有退路——而且**眼镜不在 SECTION 9 的八条验收清单里**，它掉了不等于烂尾。

## 今晚实测出的四条硬事实

1. **服务端 `authorized()` 是 `!token || Bearer 匹配`** —— 没设令牌时设备通道全部放行。
   这解释了此前提出的置空方案；公网设备通道会因此对所有人开放，现场优先用临时令牌并在演示后轮换。
2. **`trustedRequest()` 只放行 `127.0.0.1` / `localhost` / `ARIA_PUBLIC_HOSTS`**。
   手机用局域网 IP 打过来若 `ARIA_PUBLIC_HOSTS` 没带上这个 IP，会得到 **403 而不是 401**，
   极容易误判成令牌问题。`booth-console.sh` 已处理。
3. **刺激是模型调用的扳机。** `runtime.nextBee()` 有道门：蜂只在自己局部窗口里出现刺激或痕迹时
   才发起决策。没刺激 → `modelCalls` 永远是 0。
   实测：注入 6 条刺激后 `modelCalls` 从 0 → 12，账本 12 条 `provider.requested`。
   **推论：眼镜掉了，观众触屏/挥手一样能把蜂群 AI 点着**（那个入口免令牌，是真的）。
4. **本机 AI 是通的** —— key 有效、网络可达，不需要 Clash TUN。之前误判"出不去网"是没喂刺激。

## 甲档：请 Ricky 提供临时操作员令牌

此前在 PR #43 提出过置空方案：https://github.com/rickyke2023-ctrl/aria-swarm/pull/43#issuecomment-5801496793。当前建议改为短期令牌。

微信/飞书短话术（可直接复制）：

> Ricky，眼镜 App 的无签名设备目标构建已经通过，生产设备通道仍需操作员令牌。请为今天的联调设置一个临时 `ARIA_OPERATOR_TOKEN`，通过私下渠道发我，演示后轮换；不要贴在 PR 或网页里。我拿到后会拍一张新照片，核对生产的 device 刺激、蜂决策和音符因果。若现在不方便，我会用自带实例演示，并明确标为备用场次。

## 乙档：自带笔记本起一场（不靠任何人）

跑的是 `aria-swarm` 真代码（`origin/main`，不是 mock），令牌我们自己设。

```bash
# 笔记本连好场馆 Wi-Fi 后（手机也要连同一个 Wi-Fi）
./booth-console.sh                    # 起服务 + 自检 + 打印手机要填的两行
./booth-console.sh --check-only       # 服务已在跑，只做自检
ARIA_OPERATOR_TOKEN=xxx ./booth-console.sh
```

实测输出（2026-09-24 03:35，本机）：

```
  ok   本机 health (200)
  ok   手机路径 health (200)          ← 403 那个坑已绕过
  ok   无令牌上报被拒 (401)
  ok   场次在跑 runId=60a26a06…
  ok   带令牌上报 (200)
  ok   模型已配置
  ok   蜂真的在思考：modelCalls=9     ← 真实模型调用
自检 6 项通过 / 0 项失败。
```

脚本会打印手机要填的两行（App「设备」tab → 蜂群中台）：中台地址 `http://<笔记本IP>:4173`、令牌 `booth-2026`。

**诚实边界**：这是我们自己的第二场实例，**不能冒充 `ytd.rickyke.com` 那场**。
演示时如实说"这是我们本地起的同一份代码"，反而是"能独立复现"的加分。

## 丙档：眼镜改走样本通道（令牌和笔记本都没有时）

眼镜今天真实采的 JPEG（14,980 字节、368×480，在 `../glasses-dev/captures/`）照样能进账本，
但**必须如实标成采集样本，不能冒充实时**。实时性交给观众触屏/挥手——那个入口免令牌、是真的。

红线：`sample` 不得标成实时采集。这条不能破。

## 丁档：眼镜完全挂掉

眼镜只做展示道具：递给观众看、讲 BLE 四条通道（AA12/AA13/AA14/AA15）。
蜂群靠观众触屏/挥手 + 网页虚拟刺激驱动。SECTION 9 八条照样闭环。

## 真机装机命令（乙档前提）

`project.yml` 已补 `NSAppTransportSecurity: NSAllowsLocalNetworking: true`——
**没有它，iOS 会拦死明文 http，手机连局域网中台直接失败**。
2026-09-24 09:02 已在 agent 环境重跑 `xcodegen` 和无签名 iOS device 构建，修复两处 Swift 编译错误后 **BUILD SUCCEEDED**。签名安装仍需 iPhone 连接、解锁并在 `devicectl` 中可用；当前设备为 unavailable。手机在线后在自己的终端执行：

```bash
PROJ="/Users/simon/Documents/01_AI and Code Development/EvoTavern 进化酒馆黑客松/luma-companion"
cd "$PROJ" && xcodegen    # 重新生成工程，让 project.yml 的 ATS 生效
cd "$PROJ" && xcodebuild -project LumaCompanion.xcodeproj -scheme LumaCompanion \
  -destination 'platform=iOS,id=00008130-001E35880A90001C' \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -derivedDataPath /tmp/lumacompanion-dd build
xcrun devicectl device install app --device 00008130-001E35880A90001C \
  /tmp/lumacompanion-dd/Build/Products/Debug-iphoneos/LumaCompanion.app
```

这次构建顺带让 `SwarmLink.swift` 的 `source.adapter` 从 `lumacompanion` 变成 `glasses`。
**不改也能跑**（服务端只校验非空），是一致性问题不是可用性问题——构建排不上就别为它熬夜。

## 现场时间线建议

- 到场第一件事不是测眼镜，是**跑一次 `booth-console.sh` 看 modelCalls 有没有涨**。
- 令牌到了 → App 中台地址改回 `https://ytd.rickyke.com`，填他给的值。
- 令牌没到 → 用笔记本那场，App 地址填脚本打印的局域网地址。
- 眼镜没连上 → 观众触屏顶上，蜂群 AI 照样转（见上面第 3 条）。
