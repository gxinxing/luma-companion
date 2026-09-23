//
//  LumaCompanionApp.swift
//  打开 App → 自动连接眼镜 → 拍摄 / 实时画面 / 记忆 / 设备。
//

import SwiftUI

@main
struct LumaCompanionApp: App {
    @StateObject private var link = GlassesLink()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(link)
                .preferredColorScheme(.dark)
                .tint(.lumaAccent)
                .onAppear { link.start() }
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject private var link: GlassesLink

    var body: some View {
        TabView {
            CaptureView()
                .tabItem { Label("拍摄", systemImage: "camera.aperture") }

            LiveScreen(link: link)
                .tabItem { Label("实时", systemImage: "video.fill") }

            MemoriesScreen(link: link)
                .tabItem { Label("记忆", systemImage: "square.grid.2x2.fill") }

            DeviceView()
                .tabItem { Label("设备", systemImage: "eyeglasses") }
        }
    }
}
