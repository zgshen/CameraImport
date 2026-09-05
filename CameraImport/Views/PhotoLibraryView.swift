//
//  PhotoLibraryView.swift
//  CameraImport
//
//  Created by Sylvan on 9/3/26.
//

import SwiftUI

/// 相册网格：时间倒序、支持多选分享
struct PhotoLibraryView: View {
    @ObservedObject var manager: CameraManager

    @State private var selectionMode = false
    @State private var selected: Set<ObjectIdentifier> = []
    @State private var shareItems: [Any] = []
    @State private var showingShare = false
    @State private var isPreparingShare = false
    @State private var dragState = DragSelectionState()

    private let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]

    var body: some View {
        content
            .navigationTitle(manager.cameraName ?? "相机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        manager.toggleSortOrder()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                            Text(manager.sortOrder == .newestFirst ? "最新优先" : "最旧优先")
                        }
                    }
                    .disabled(manager.files.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !manager.files.isEmpty {
                        Button(selectionMode ? "完成" : "选择") {
                            selectionMode.toggle()
                            if !selectionMode { selected.removeAll() }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selectionMode {
                    selectionBar
                }
            }
            .sheet(isPresented: $showingShare) {
                ShareSheet(items: shareItems)
            }
            .navigationDestination(for: CameraFile.self) { file in
                PhotoDetailView(file: file, manager: manager)
            }
    }

    @ViewBuilder
    private var content: some View {
        if manager.files.isEmpty {
            if manager.isEnumerating {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在读取设备内容…")
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView(
                    "设备中没有图片",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("请检查设备中是否有照片或视频")
                )
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(manager.files) { file in
                    cell(for: file)
                        .onAppear {
                            manager.loadThumbnail(for: file)
                            manager.loadMetadata(for: file)
                        }
                }
            }
            // coordinateSpace 放在内容网格上，滚动时单元格坐标保持稳定
            .coordinateSpace(name: "grid")
            .onPreferenceChange(CellFrameKey.self) { dragState.frames = $0 }
            .simultaneousGesture(selectionDragGesture())
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private func cell(for file: CameraFile) -> some View {
        Group {
            if selectionMode {
                Button {
                    toggleSelection(file)
                } label: {
                    FileCellView(
                        file: file,
                        selectionMode: true,
                        isSelected: selected.contains(file.id)
                    )
                }
            } else {
                NavigationLink(value: file) {
                    FileCellView(file: file, selectionMode: false, isSelected: false)
                }
            }
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: CellFrameKey.self,
                    value: [file.id: geo.frame(in: .named("grid"))]
                )
            }
        )
    }

    private var selectionBar: some View {
        ZStack {
            Text("已选择 \(selected.count) 项")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    toggleSelectAll()
                } label: {
                    Text(selected.count == manager.files.count ? "取消全选" : "全选")
                        .font(.subheadline)
                }

                Spacer()

                if isPreparingShare {
                    ProgressView()
                } else {
                    Button {
                        prepareShare()
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .font(.headline)
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - 动作

    private func toggleSelection(_ file: CameraFile) {
        if selected.contains(file.id) {
            selected.remove(file.id)
        } else {
            selected.insert(file.id)
        }
    }

    private func toggleSelectAll() {
        if selected.count == manager.files.count {
            selected.removeAll()
        } else {
            selected = Set(manager.files.map(\.id))
        }
    }

    /// 滑动框选：从按住点拖到当前位置，两者围成的矩形区域内的图片被选中/取消（与系统相册一致）
    private func selectionDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named("grid"))
            .onChanged { value in
                guard selectionMode else { return }
                if !dragState.isActive {
                    dragState.isActive = true
                    dragState.anchor = value.startLocation
                    dragState.base = selected
                    dragState.mode = cell(at: value.startLocation).map { !selected.contains($0) } ?? true
                }
                applyMarquee(from: dragState.anchor, to: value.location)
            }
            .onEnded { _ in
                dragState.isActive = false
                dragState.base = []
            }
    }

    /// 框选：以锚点为起点按行选中。
    /// - 向下滑：上方各行整行全选，最底行左对齐选到最右列（例：1→5 选中 1 2 3 4 5）
    /// - 向上滑：下方各行整行全选，最顶行右对齐选到最左列（例：5→2 不选 1）
    private func applyMarquee(from anchor: CGPoint, to current: CGPoint) {
        guard
            let anchorID = cell(at: anchor),
            let currentID = cell(at: current),
            let aIndex = manager.files.firstIndex(where: { $0.id == anchorID }),
            let cIndex = manager.files.firstIndex(where: { $0.id == currentID })
        else { return }

        let colCount = columns.count
        let aRow = aIndex / colCount, aCol = aIndex % colCount
        let cRow = cIndex / colCount, cCol = cIndex % colCount

        var result = dragState.base
        for (index, file) in manager.files.enumerated() {
            let row = index / colCount
            let col = index % colCount

            let inSelection: Bool
            if aRow == cRow {
                // 同一行：选中左右两列之间
                inSelection = row == aRow && col >= min(aCol, cCol) && col <= max(aCol, cCol)
            } else if aRow < cRow {
                // 向下：上方整行全选，最底行左对齐选到最右列
                inSelection = row >= aRow && row <= cRow && (row < cRow || col <= max(aCol, cCol))
            } else {
                // 向上：下方整行全选，最顶行右对齐选到最左列
                inSelection = row >= cRow && row <= aRow && (row > cRow || col >= min(aCol, cCol))
            }

            if inSelection {
                if dragState.mode {
                    result.insert(file.id)
                } else {
                    result.remove(file.id)
                }
            }
        }
        selected = result
    }

    /// 返回覆盖指定点的单元格 id
    private func cell(at point: CGPoint) -> ObjectIdentifier? {
        dragState.frames.first { $0.value.contains(point) }?.key
    }

    private func prepareShare() {
        let selectedFiles = manager.files.filter { selected.contains($0.id) }
        guard !selectedFiles.isEmpty else { return }
        isPreparingShare = true
        manager.prepareShareItems(for: selectedFiles) { items in
            isPreparingShare = false
            shareItems = items
            showingShare = true
        }
    }
}

// MARK: - 单元格位置偏好键

/// 收集单元格在 grid 坐标系中的位置
private struct CellFrameKey: PreferenceKey {
    static var defaultValue: [ObjectIdentifier: CGRect] = [:]
    static func reduce(value: inout [ObjectIdentifier: CGRect], nextValue: () -> [ObjectIdentifier: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - 拖动多选状态

/// 滑动框选状态（存为类实例：frames 变化不触发视图刷新，只有 selected 变化才刷新）
private final class DragSelectionState {
    var frames: [ObjectIdentifier: CGRect] = [:]   // 每个单元格在 grid 坐标系中的位置
    var base: Set<ObjectIdentifier> = []            // 框选开始前的选中集合
    var mode: Bool = true                           // true=框选为选中，false=取消
    var anchor: CGPoint = .zero                     // 框选起点
    var isActive = false                            // 是否正在框选
}

// MARK: - 单元格

/// 单个文件单元格（观察 file，缩略图/日期变化可实时刷新）
private struct FileCellView: View {
    @ObservedObject var file: CameraFile
    let selectionMode: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail

                if selectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .white)
                        .shadow(radius: 1)
                        .padding(6)
                } else if file.isVideo {
                    Text("视频")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(6)
                } else if file.isRaw {
                    Text("RAW")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(6)
                }
            }

            Text(file.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)

            if !file.dateText.isEmpty {
                Text(file.dateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !file.fileSizeText.isEmpty {
                Text(file.fileSizeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var thumbnail: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let cg = file.thumbnail {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(Color(.secondarySystemBackground))
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
