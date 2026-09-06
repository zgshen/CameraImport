//
//  ContentView.swift
//  CameraImport
//
//  Created by Sylvan on 9/3/26.
//

import SwiftUI

/// 导航路由：进入相册 / 进入大图预览
enum Route: Hashable {
    case library
    case detail(CameraFile)
}

struct ContentView: View {
    @StateObject private var manager = CameraManager()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch manager.state {
                case .searching:
                    SearchingView(onReconnect: manager.reconnect)
                case .opening(let name):
                    OpeningView(name: name)
                case .ready:
                    DeviceView(manager: manager, path: $path)
                case .disconnected:
                    DisconnectedView(onReconnect: manager.reconnect)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .library:
                    PhotoLibraryView(manager: manager, path: $path)
                case .detail(let file):
                    PhotoDetailView(file: file, manager: manager)
                }
            }
        }
        .onChange(of: manager.state) { _, newState in
            // 设备断开或状态切换时，退回根视图
            if case .ready = newState { return }
            path = NavigationPath()
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
            Text(L10n.tr("searching.title"))
                .font(.title2)
                .bold()
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.tr("searching.hint.usb"), systemImage: "cable.connector")
                Label(L10n.tr("searching.hint.power"), systemImage: "power")
                Label(L10n.tr("searching.hint.mode"), systemImage: "switch.2")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding()
            Button(L10n.tr("searching.rescan"), action: onReconnect)
                .buttonStyle(.borderedProminent)
            Spacer()
            Spacer()
        }
        .padding()
        .navigationTitle(L10n.tr("nav.import"))
    }
}

/// 正在连接设备
struct OpeningView: View {
    let name: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(String(format: L10n.tr("opening.connecting"), name))
                .foregroundStyle(.secondary)
        }
        .navigationTitle(L10n.tr("nav.import"))
    }
}

/// 已连接设备（点击进入相册）
struct DeviceView: View {
    @ObservedObject var manager: CameraManager
    @Binding var path: NavigationPath

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Button {
                path.append(Route.library)
            } label: {
                VStack(spacing: 14) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text(manager.cameraName ?? L10n.tr("device.connected"))
                        .font(.title3)
                        .bold()
                        .foregroundStyle(.primary)
                    Text(L10n.tr("device.tap.hint"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
                .padding(.horizontal, 20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 24)
            }
            .buttonStyle(.plain)
            Spacer()
            Spacer()
        }
        .navigationTitle(L10n.tr("nav.import"))
    }
}

/// 设备已断开
struct DisconnectedView: View {
    let onReconnect: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(L10n.tr("disconnected.title"), systemImage: "camera.badge.ellipsis")
        } description: {
            Text(L10n.tr("disconnected.hint"))
        } actions: {
            Button(L10n.tr("disconnected.reconnect"), action: onReconnect)
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle(L10n.tr("nav.import"))
    }
}

// MARK: - 本地化

/// 轻量国际化：按系统首选语言返回中文/英文字符串（无需 .strings 资源文件）
enum L10n {
    static func tr(_ key: String) -> String {
        let lang = Locale.preferredLanguages.first ?? "en"
        let dict = lang.lowercased().hasPrefix("zh") ? zh : en
        return dict[key] ?? en[key] ?? key
    }

    static let en: [String: String] = [
        "nav.import": "Import",
        "searching.title": "No camera or card reader detected",
        "searching.hint.usb": "Connect a camera or card reader with a USB cable",
        "searching.hint.power": "Turn the camera on; insert an SD card into the reader",
        "searching.hint.mode": "Some cameras need USB/PC connection mode selected",
        "searching.rescan": "Search Again",
        "opening.connecting": "Connecting to %@…",
        "disconnected.title": "Device Disconnected",
        "disconnected.hint": "Reconnect the device and try again",
        "disconnected.reconnect": "Reconnect",
        "device.connected": "Device Connected",
        "device.camera": "Camera",
        "device.open.library": "Open Library",
        "device.tap.hint": "Tap to browse photos and videos",
        "library.sort": "Sort Order",
        "library.sort.newest": "Newest First",
        "library.sort.oldest": "Oldest First",
        "library.select": "Select",
        "library.done": "Done",
        "library.selected.count": "%d items selected",
        "library.select.all": "Select All",
        "library.deselect.all": "Deselect All",
        "library.share": "Share",
        "library.enumerating": "Reading device content…",
        "library.empty.title": "No Photos on Device",
        "library.empty.hint": "Check that the device contains photos or videos",
        "library.badge.video": "Video",
        "detail.back": "Back",
        "detail.loading": "Loading…",
        "detail.decoding": "Decoding…",
        "detail.loading.video": "Loading video…",
        "detail.raw.unavailable": "Can't preview this RAW",
        "detail.load.failed": "Load Failed",
        "detail.decode.failed.image": "Couldn't decode this image",
        "detail.decode.failed.raw": "Couldn't decode this RAW file",
        "error.notAFile": "Not a valid image file",
        "error.unknown": "Unknown error",
        "error.decode.raw": "Couldn't decode this RAW file (%@)",
        "file.unnamed": "Unnamed",
    ]

    static let zh: [String: String] = [
        "nav.import": "导入",
        "searching.title": "未检测到相机/读卡器",
        "searching.hint.usb": "使用 USB 线连接相机或读卡器",
        "searching.hint.power": "相机需开机；读卡器需插入 SD 卡",
        "searching.hint.mode": "部分相机需选择 USB / PC 连接模式",
        "searching.rescan": "重新搜索",
        "opening.connecting": "正在连接 %@…",
        "disconnected.title": "设备已断开",
        "disconnected.hint": "请重新连接设备后重试",
        "disconnected.reconnect": "重新连接",
        "device.connected": "已连接设备",
        "device.camera": "相机",
        "device.open.library": "进入相册",
        "device.tap.hint": "点击进入相册浏览照片和视频",
        "library.sort": "排序方式",
        "library.sort.newest": "最新优先",
        "library.sort.oldest": "最旧优先",
        "library.select": "选择",
        "library.done": "完成",
        "library.selected.count": "已选择 %d 项",
        "library.select.all": "全选",
        "library.deselect.all": "取消全选",
        "library.share": "分享",
        "library.enumerating": "正在读取设备内容…",
        "library.empty.title": "设备中没有图片",
        "library.empty.hint": "请检查设备中是否有照片或视频",
        "library.badge.video": "视频",
        "detail.back": "返回",
        "detail.loading": "正在加载…",
        "detail.decoding": "正在解码…",
        "detail.loading.video": "正在加载视频…",
        "detail.raw.unavailable": "无法预览该 RAW",
        "detail.load.failed": "加载失败",
        "detail.decode.failed.image": "无法解码该图片",
        "detail.decode.failed.raw": "无法解码该 RAW 文件",
        "error.notAFile": "不是有效的图片文件",
        "error.unknown": "未知错误",
        "error.decode.raw": "无法解码该 RAW 文件（%@）",
        "file.unnamed": "未命名",
    ]
}

#Preview {
    ContentView()
}
