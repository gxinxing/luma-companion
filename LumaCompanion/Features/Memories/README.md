# 本地记忆页

`LocalMemoriesScreen.swift` 是当前手机导航中的「记忆」页，只读取 `CaptureStore` 保存的 BLE 回传小图，支持查看、分享、存入系统相册和删除，不启动眼镜 Wi-Fi。`MemoriesScreen.swift` 是旧热点相册实现，仍在源码中，但当前 `RootTabView` 没有入口。

从用户终端：在 `luma-companion/` 运行 `xcodegen`，用 Xcode 打开 `LumaCompanion.xcodeproj`，选择真机运行；记忆页无需眼镜热点。需要真实照片时先在「感知」页连接眼镜并拍照。

从 agent shell：在 `luma-companion/` 运行 `xcodegen generate`，再运行 `xcodebuild -project LumaCompanion.xcodeproj -scheme LumaCompanion -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`。模拟器可检查空态和导航，但无法验证 BLE 回传。

验证于 2026-09-24 09:35 Asia/Shanghai：iOS device 与 Simulator 构建通过；模拟器人工检查记忆空态和「去感知」导航。iPhone 当时 unavailable，照片回传、分享和相册保存仍待真机验收。完整当前状态见 [`../../../../PROJECT_CONTEXT.md`](../../../../PROJECT_CONTEXT.md)。
