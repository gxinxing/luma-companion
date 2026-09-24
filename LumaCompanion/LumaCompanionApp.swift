//
//  LumaCompanionApp.swift
//  打开 App → 自动连接眼镜 → BLE 拍摄 / 本地记忆 / 设备。
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
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            CaptureView()
                .tabItem { Label("感知", systemImage: "viewfinder") }
                .tag(0)

            LocalMemoriesScreen(onCapture: { selectedTab = 0 })
                .tabItem { Label("记忆", systemImage: "square.grid.2x2.fill") }
                .tag(1)

            DeviceView()
                .tabItem { Label("蜂群", systemImage: "circle.hexagongrid") }
                .tag(2)
        }
    }
}
