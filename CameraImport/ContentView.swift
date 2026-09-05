//
//  ContentView.swift
//  CameraImport
//
//  Created by Sylvan on 9/3/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var manager = CameraManager()

    var body: some View {
        NavigationStack {
            Group {
                switch manager.state {
                case .searching:
                    SearchingView(onReconnect: manager.reconnect)
                case .opening(let name):
                    OpeningView(name: name)
                case .ready:
                    PhotoLibraryView(manager: manager)
                case .disconnected:
                    DisconnectedView(onReconnect: manager.reconnect)
                }
            }
        }
    }
}

/// 未检测到相机/读卡器
struct SearchingView: View {
    let onReconnect: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "camera.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("未检测到相机/读卡器")
                .font(.title2)
                .bold()
            VStack(alignment: .leading, spacing: 10) {
                Label("使用 USB 线连接相机或读卡器", systemImage: "cable.connector")
                Label("相机需开机；读卡器需插入 SD 卡", systemImage: "power")
                Label("部分相机需选择 USB / PC 连接模式", systemImage: "switch.2")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding()
            Button("重新搜索", action: onReconnect)
                .buttonStyle(.borderedProminent)
            Spacer()
            Spacer()
        }
        .padding()
        .navigationTitle("导入")
    }
}

/// 正在连接设备
struct OpeningView: View {
    let name: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("正在连接 \(name)…")
                .foregroundStyle(.secondary)
        }
        .navigationTitle("导入")
    }
}

/// 设备已断开
struct DisconnectedView: View {
    let onReconnect: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("设备已断开", systemImage: "camera.badge.ellipsis")
        } description: {
            Text("请重新连接设备后重试")
        } actions: {
            Button("重新连接", action: onReconnect)
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle("导入")
    }
}

#Preview {
    ContentView()
}
