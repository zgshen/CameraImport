//
//  PhotoDetailView.swift
//  CameraImport
//
//  Created by Sylvan on 9/3/26.
//

import SwiftUI
import AVFoundation

/// 大图预览 + 系统分享（支持左右滑动切换上一张/下一张）
struct PhotoDetailView: View {
    @ObservedObject var manager: CameraManager
    @State private var currentFile: CameraFile

    @State private var shareItems: [Any] = []
    @State private var showingShare = false
    @State private var isPreparingShare = false

    init(file: CameraFile, manager: CameraManager) {
        self._manager = ObservedObject(wrappedValue: manager)
        self._currentFile = State(initialValue: file)
    }

    var body: some View {
        TabView(selection: $currentFile) {
            ForEach(manager.files) { file in
                PhotoPageView(file: file, manager: manager)
                    .tag(file)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.white)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    prepareShare()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(isPreparingShare)
            }
        }
        .overlay(alignment: .bottom) {
            infoBar
        }
        .sheet(isPresented: $showingShare) {
            ShareSheet(items: shareItems)
        }
    }

    private var infoBar: some View {
        VStack(spacing: 2) {
            Text(currentFile.name)
                .font(.caption)
                .bold()
            if let date = currentFile.creationDate {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
            }
        }
        .foregroundStyle(.primary)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 8)
    }

    private func loadImage(for file: CameraFile) {
        guard file.fullImage == nil else { return }
        manager.decodedImage(for: file) { image in
            file.fullImage = image
            if image == nil && file.thumbnail == nil && file.loadError == nil {
                file.loadError = "无法解码该图片"
            }
        }
    }

    private func prepareShare() {
        isPreparingShare = true
        manager.prepareShareItems(for: [currentFile]) { items in
            isPreparingShare = false
            shareItems = items
            showingShare = true
        }
    }
}

/// 单张大图/视频页面（观察 file，加载完成/失败可实时刷新）
private struct PhotoPageView: View {
    @ObservedObject var file: CameraFile
    @ObservedObject var manager: CameraManager

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            if file.isVideo {
                videoContent
            } else if let image = file.fullImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if file.isRaw {
                // RAW：不显示网格小图，避免把缩略图误当成预览结果
                if let error = file.loadError {
                    ContentUnavailableView(
                        "无法预览该 RAW",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(file.isLoadingFull ? "正在加载…" : "正在解码…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let cg = file.thumbnail {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if file.isLoadingFull {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在加载…")
                        .foregroundStyle(.secondary)
                }
            } else if let error = file.loadError {
                ContentUnavailableView(
                    "加载失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ProgressView()
            }
        }
        .task {
            load()
        }
    }

    @ViewBuilder
    private var videoContent: some View {
        if let url = file.videoURL {
            VideoPlayerView(url: url)
        } else if let cg = file.thumbnail {
            Image(decorative: cg, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在加载视频…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() {
        if file.isVideo {
            guard file.videoURL == nil else { return }
            manager.loadVideoURL(for: file) { _ in }
        } else {
            loadImage()
        }
    }

    private func loadImage() {
        guard file.fullImage == nil else { return }
        manager.decodedImage(for: file) { image in
            file.fullImage = image
            if image == nil && (file.isRaw || file.thumbnail == nil) && file.loadError == nil {
                file.loadError = file.isRaw ? "无法解码该 RAW 文件" : "无法解码该图片"
            }
        }
    }
}

/// 视频播放器：默认自动播放，带播放/暂停图标与进度条，播放时控件自动隐藏；静音模式下也有声音
private struct VideoPlayerView: View {
    let url: URL
    @StateObject private var model = VideoPlayerModel()

    var body: some View {
        ZStack {
            Color.black
            PlayerLayerView(player: model.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.showControls {
                controls
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.revealControls()
        }
        .onAppear {
            model.load(url: url)
        }
        .onDisappear {
            model.stop()
        }
    }

    private var controls: some View {
        VStack {
            Spacer()
            HStack(spacing: 16) {
                Button {
                    model.togglePlayPause()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                }

                VStack(spacing: 4) {
                    Slider(
                        value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }),
                        in: 0...max(model.duration, 0.01)
                    )
                    .tint(.white)

                    HStack {
                        Text(timeText(model.currentTime))
                        Spacer()
                        Text(timeText(model.duration))
                    }
                    .font(.caption2)
                    .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 视频播放状态与控制逻辑
private final class VideoPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var showControls = true

    let player = AVPlayer()
    private var timeObserver: Any?
    private var hideWorkItem: DispatchWorkItem?

    func load(url: URL) {
        // onAppear 可能多次触发，避免重复加载
        guard timeObserver == nil else { return }

        // 使用 .playback 类别：系统静音开关下也照常发声
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        player.replaceCurrentItem(with: AVPlayerItem(url: url))

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                self.duration = d
            }
            self.isPlaying = self.player.rate > 0
        }

        player.play()
        isPlaying = true
        showControls = true
        scheduleAutoHide()
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
            showControls = true
            hideWorkItem?.cancel()
        } else {
            player.play()
            scheduleAutoHide()
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
    }

    func revealControls() {
        if showControls {
            showControls = false
            hideWorkItem?.cancel()
        } else {
            showControls = true
            scheduleAutoHide()
        }
    }

    func stop() {
        hideWorkItem?.cancel()
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            self.timeObserver = nil
        }
        player.pause()
    }

    private func scheduleAutoHide() {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isPlaying else { return }
            self.showControls = false
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }
}

/// 把 AVPlayer 的画面显示到 SwiftUI
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
