//
//  Theme.swift
//  First-person field recorder: dark, low-noise, viewfinder-first.
//

import SwiftUI

extension ShapeStyle where Self == Color {
    static var lumaBackground: Color { Color(red: 0.055, green: 0.067, blue: 0.075) }
    static var lumaSurface: Color { Color(red: 0.105, green: 0.12, blue: 0.13) }
    static var lumaStroke: Color { Color.white.opacity(0.10) }
    /// Warm amber — the capture light. Dark-mode friendly, deliberately not the
    /// stock vendor app's yellow.
    static var lumaAccent: Color { Color(red: 0.98, green: 0.72, blue: 0.16) }
    /// The recording state: red, used only while a transfer is in flight.
    static var lumaRecording: Color { Color(red: 0.93, green: 0.27, blue: 0.19) }
}

/// The connection status pill every page can pin at its top.
struct StatusPill: View {
    @EnvironmentObject private var link: GlassesLink

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(headline)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let battery = link.batteryPercent, link.phase.isConnected {
                Spacer(minLength: 4)
                Image(systemName: link.charging ? "battery.100.bolt" : "battery.75percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(battery)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Spacer(minLength: 4)
            }
            if link.phase.isWorking {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var headline: String {
        switch link.phase {
        case .idle: "未连接"
        case .bluetoothOff: "蓝牙\(subtitle ?? "")"
        case .scanning: "正在寻找眼镜…"
        case .connecting: "正在连接\(nameText)…"
        case .discovering: "正在握手…"
        case .connected: nameText.isEmpty ? "已连接" : nameText
        case .failed: subtitle ?? "连接失败"
        }
    }
    private var subtitle: String? {
        if case let .bluetoothOff(reason) = link.phase { return reason == "off" ? "未开启" : reason }
        if case let .failed(reason) = link.phase { return reason }
        return nil
    }
    private var nameText: String { link.deviceName ?? "" }
    private var dotColor: Color {
        switch link.phase {
        case .connected: .green
        case .scanning, .connecting, .discovering: .lumaAccent
        case .failed: .lumaRecording
        case .bluetoothOff: .secondary
        case .idle: .secondary
        }
    }
}
