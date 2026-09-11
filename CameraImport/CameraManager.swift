//
//  CameraManager.swift
//  CameraImport
//
//  Created by Sylvan on 9/3/26.
//

import Foundation
import Combine
import ImageCaptureCore
import UIKit
import AVFoundation
import ImageIO
import CoreImage
import QuickLookThumbnailing

/// 相机连接状态
enum CameraState: Equatable {
    case searching
    case opening(String)
    case ready
    case disconnected
}

/// 排序方式
enum SortOrder: Hashable {
    case newestFirst
    case oldestFirst
}

/// 相机文件包装模型
final class CameraFile: ObservableObject, Identifiable, Hashable {
    let item: ICCameraItem

    @Published var thumbnail: CGImage?
    @Published var data: Data?
    @Published var fullImage: UIImage?
    @Published var isLoadingFull = false
    @Published var loadError: String?
    @Published var videoURL: URL?

    var id: ObjectIdentifier { ObjectIdentifier(item) }

    var name: String { item.name ?? L10n.tr("file.unnamed") }

    /// 拍摄日期（用于排序），可被元数据更新
    @Published var creationDate: Date?

    /// 文件大小（字节）
    var fileSize: Int64 {
        guard let file = item as? ICCameraFile else { return 0 }
        return Int64(file.fileSize)
    }

    var fileSizeText: String {
        guard fileSize > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d/M/yy"
        return formatter
    }()

    var dateText: String {
        guard let date = creationDate else { return "" }
        return Self.shortDateFormatter.string(from: date)
    }

    /// 依据扩展名判断是否为 RAW
    var isRaw: Bool {
        let ext = Self.pathExtension(of: name)
        return Self.rawExtensions.contains(ext)
    }

    /// 依据扩展名判断是否为视频
    var isVideo: Bool {
        Self.videoExtensions.contains(Self.pathExtension(of: name))
    }

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif",
        "raf", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "pef", "srw", "x3f"
    ]
    static let rawExtensions: Set<String> = [
        "raf", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "pef", "srw", "x3f"
    ]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv"]
    static let mediaExtensions: Set<String> = {
        var set = imageExtensions
        set.formUnion(videoExtensions)
        return set
    }()

    static func pathExtension(of name: String?) -> String {
        guard let name else { return "" }
        return (name as NSString).pathExtension.lowercased()
    }

    init(item: ICCameraItem) {
        self.item = item
        if let date = item.creationDate {
            self.creationDate = date
        } else if let file = item as? ICCameraFile {
            self.creationDate = file.exifCreationDate ?? file.fileCreationDate
        }
    }

    /// 用元数据更新拍摄日期
    func updateDate(from metadata: [AnyHashable: Any]?) {
        if let date = CameraFile.captureDate(from: metadata) {
            creationDate = date
        } else if let file = item as? ICCameraFile, let date = file.exifCreationDate {
            creationDate = date
        }
    }

    /// 从元数据字典中提取拍摄日期
    static func captureDate(from metadata: [AnyHashable: Any]?) -> Date? {
        guard let metadata else { return nil }

        if let exif = metadata["{Exif}"] as? [AnyHashable: Any] {
            for key in ["DateTimeOriginal", "DateTimeDigitized"] {
                if let str = exif[key] as? String, let date = Self.parseDateString(str) {
                    return date
                }
            }
        }

        if let tiff = metadata["{TIFF}"] as? [AnyHashable: Any],
           let str = tiff["DateTime"] as? String,
           let date = Self.parseDateString(str) {
            return date
        }

        return nil
    }

    private static func parseDateString(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let date = formatter.date(from: string) { return date }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)
    }

    static func == (lhs: CameraFile, rhs: CameraFile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum CameraImportError: LocalizedError {
    case notAFile
    case unknown

    var errorDescription: String? {
        switch self {
        case .notAFile: return L10n.tr("error.notAFile")
        case .unknown: return L10n.tr("error.unknown")
        }
    }
}

/// 相机连接 / 文件读取管理器
final class CameraManager: NSObject, ObservableObject {
    @Published var state: CameraState = .searching
    @Published var files: [CameraFile] = []
    @Published var cameraName: String?
    @Published var lastErrorMessage: String?
    @Published var sortOrder: SortOrder = .newestFirst
    @Published var isEnumerating = false

    private let browser = ICDeviceBrowser()
    private weak var camera: ICCameraDevice?
    private var fileLookup: [ObjectIdentifier: CameraFile] = [:]
    private var discoveredItems: [ICCameraItem] = []
    private var discoveredIDs: Set<ObjectIdentifier> = []
    private var requestedThumbnails: Set<ObjectIdentifier> = []
    private var requestedMetadata: Set<ObjectIdentifier> = []
    private var dataCompletions: [ObjectIdentifier: [(Result<Data, Error>) -> Void]] = [:]
    private var rebuildWorkItem: DispatchWorkItem?
    private var enumerationTimeoutWorkItem: DispatchWorkItem?
    private var localThumbnailJobs: Set<ObjectIdentifier> = []
    private var catalogComplete = false

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = .camera
        browser.start()
    }

    deinit {
        browser.delegate = nil
        browser.stop()
    }

    // MARK: - 对外接口

    func reconnect() {
        state = .searching
        cameraName = nil
        lastErrorMessage = nil
        camera = nil
        files = []
        fileLookup = [:]
        discoveredItems = []
        discoveredIDs = []
        requestedThumbnails = []
        requestedMetadata = []
        dataCompletions = [:]
        localThumbnailJobs = []
        catalogComplete = false
        rebuildWorkItem?.cancel()
        enumerationTimeoutWorkItem?.cancel()
        isEnumerating = false
        if !browser.isBrowsing {
            browser.start()
        }
    }

    /// 切换排序（最新 ↔ 最旧）
    func toggleSortOrder() {
        sortOrder = (sortOrder == .newestFirst) ? .oldestFirst : .newestFirst
        rebuildFiles()
    }

    /// 加载完整文件数据（带缓存，支持多请求共享）
    func loadFullData(for file: CameraFile, completion: @escaping (Result<Data, Error>) -> Void) {
        let key = file.id
        if let data = file.data {
            completion(.success(data))
            return
        }
        guard let cameraFile = file.item as? ICCameraFile else {
            completion(.failure(CameraImportError.notAFile))
            return
        }
        dataCompletions[key, default: []].append(completion)
        if file.isLoadingFull { return }
        file.isLoadingFull = true
        file.loadError = nil
        downloadFullData(cameraFile, file: file, key: key)
    }

    /// 优先用 requestDownload 下载完整文件（读卡器/大容量存储走文件复制，更可靠），
    /// 失败时退回分块 requestReadData（PTP 相机）。
    private func downloadFullData(_ cameraFile: ICCameraFile, file: CameraFile, key: ObjectIdentifier) {
        let directory = FileManager.default.temporaryDirectory
        let options: [ICDownloadOption: Any] = [ICDownloadOption.downloadsDirectoryURL: directory]

        cameraFile.requestDownload(options: options) { [weak self] filename, error in
            DispatchQueue.main.async {
                guard let self, self.dataCompletions[key] != nil else { return }
                var data: Data?
                if let filename {
                    let url = filename.hasPrefix("/")
                        ? URL(fileURLWithPath: filename)
                        : directory.appendingPathComponent(filename)
                    data = try? Data(contentsOf: url)
                }
                if let data, !data.isEmpty {
                    self.finishDownload(file: file, key: key, data: data, error: nil)
                } else {
                    self.readFile(cameraFile, file: file, key: key, offset: 0, accumulated: Data())
                }
            }
        }
    }

    /// 分块读取文件数据（PTP 使用 GetPartialObject）
    private func readFile(_ cameraFile: ICCameraFile, file: CameraFile, key: ObjectIdentifier, offset: off_t, accumulated: Data) {
        let total = cameraFile.fileSize
        let chunkSize: off_t = 4 * 1024 * 1024
        let length: off_t
        if total > 0 {
            let remaining = total - offset
            length = min(chunkSize, max(0, remaining))
        } else {
            length = chunkSize
        }
        guard length > 0 else {
            finishDownload(file: file, key: key, data: accumulated, error: nil)
            return
        }

        cameraFile.requestReadData(atOffset: offset, length: length) { [weak self] data, error in
            DispatchQueue.main.async {
                guard let self, self.dataCompletions[key] != nil else { return }
                if let data, !data.isEmpty {
                    var next = accumulated
                    next.append(data)
                    if total > 0 {
                        if offset + off_t(data.count) >= total {
                            self.finishDownload(file: file, key: key, data: next, error: nil)
                        } else {
                            self.readFile(cameraFile, file: file, key: key, offset: offset + off_t(data.count), accumulated: next)
                        }
                    } else {
                        if off_t(data.count) < chunkSize {
                            self.finishDownload(file: file, key: key, data: next, error: nil)
                        } else {
                            self.readFile(cameraFile, file: file, key: key, offset: offset + off_t(data.count), accumulated: next)
                        }
                    }
                } else {
                    if accumulated.isEmpty {
                        self.finishDownload(file: file, key: key, data: nil, error: error)
                    } else {
                        self.finishDownload(file: file, key: key, data: accumulated, error: nil)
                    }
                }
            }
        }
    }

    private func finishDownload(file: CameraFile, key: ObjectIdentifier, data: Data?, error: Error?) {
        file.isLoadingFull = false
        guard let completions = dataCompletions.removeValue(forKey: key) else { return }
        if let data, !data.isEmpty {
            file.data = data
            completions.forEach { $0(.success(data)) }
        } else {
            let err = error ?? CameraImportError.unknown
            file.loadError = err.localizedDescription
            completions.forEach { $0(.failure(err)) }
        }
    }

    /// 解码为 UIImage（后台线程解码）
    func decodedImage(for file: CameraFile, completion: @escaping (UIImage?) -> Void) {
        loadFullData(for: file) { result in
            switch result {
            case .success(let data):
                let isRaw = file.isRaw
                let name = file.name
                DispatchQueue.global(qos: .userInitiated).async {
                    let image = Self.decodeImage(from: data, isRaw: isRaw, fileName: name)
                    DispatchQueue.main.async {
                        if image == nil, isRaw {
                            file.loadError = String(format: L10n.tr("error.decode.raw"), Self.rawDiagnostic(data))
                        }
                        completion(image)
                    }
                }
            case .failure:
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    /// 下载视频到本地临时文件（供 AVPlayer 播放）
    func loadVideoURL(for file: CameraFile, completion: @escaping (URL?) -> Void) {
        if let url = file.videoURL {
            completion(url)
            return
        }
        loadFullData(for: file) { result in
            switch result {
            case .success(let data):
                if let url = Self.writeTempFile(data: data, fileName: file.name) {
                    file.videoURL = url
                    completion(url)
                } else {
                    completion(nil)
                }
            case .failure:
                completion(nil)
            }
        }
    }

    /// 准备分享条目：始终分享原始文件 URL（保留 EXIF；RAW 保留 RAW 本体而非预览图）
    func prepareShareItems(for files: [CameraFile], completion: @escaping ([Any]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for file in files {
            group.enter()
            loadFullData(for: file) { result in
                if case .success(let data) = result,
                   let url = Self.writeTempFile(data: data, fileName: file.name) {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(urls)
        }
    }

    // MARK: - 解码与封面生成

    /// 多策略解码：常规 UIImage → QuickLook / Core Image RAW 预览
    private static func decodeImage(from data: Data, isRaw: Bool, fileName: String) -> UIImage? {
        if let image = UIImage(data: data) {
            return image
        }
        guard isRaw else { return nil }
        return rawPreview(from: data, fileName: fileName)
    }

    /// 共享的 Core Image 渲染上下文（GPU 加速，线程安全）
    private static let ciContext = CIContext()

    /// 从 RAW 解码预览：与文件 App / QuickLook 同一套 Core Image 引擎，
    /// 优先取相机内嵌预览（文件 App 显示的正是这张），失败再完整解码、再 ImageIO。
    /// RAW 预览：优先用 QuickLook（与文件 App 完全相同的引擎，能取到相机内嵌预览），
    /// 失败再用 Core Image / ImageIO 解码。
    private static func rawPreview(from data: Data, fileName: String) -> UIImage? {
        // 1) QuickLook 预览（文件 App 用的就是它）
        if let image = quickLookPreview(from: data, fileName: fileName) {
            return image
        }
        // 2) Core Image RAW：内嵌预览 / 完整解码
        if let filter = CIRAWFilter(imageData: data, identifierHint: nil) {
            let candidates: [CIImage?] = [filter.previewImage, filter.outputImage]
            for candidate in candidates {
                guard let image = candidate else { continue }
                let extent = image.extent
                guard !extent.isInfinite, extent.width > 1, extent.height > 1 else { continue }
                let maxDim: CGFloat = 3000
                let longest = max(extent.width, extent.height)
                let scale: CGFloat = longest > maxDim ? maxDim / longest : 1
                let scaled = scale == 1 ? image : image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                if let cg = ciContext.createCGImage(scaled, from: scaled.extent) {
                    return UIImage(cgImage: cg)
                }
            }
        }
        // 3) ImageIO 强制 RAW 解码（缩略图 API + 最大边长）
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let decode: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3000,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, decode as CFDictionary) {
                return UIImage(cgImage: cg)
            }
        }
        return nil
    }

    /// 用 QuickLook 生成预览（同步，后台线程调用）
    private static func quickLookPreview(from data: Data, fileName: String) -> UIImage? {
        guard let url = writeTempFile(data: data, fileName: fileName) else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 2048, height: 2048),
            scale: 2,
            representationTypes: .thumbnail
        )
        var image: UIImage?
        let semaphore = DispatchSemaphore(value: 0)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
            image = thumbnail?.uiImage
            semaphore.signal()
        }
        semaphore.wait()
        return image
    }

    /// 解码失败时的诊断信息（文件类型 + 数据大小）
    private static func rawDiagnostic(_ data: Data) -> String {
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let type = CGImageSourceGetType(source) as String? {
            return "\(type), \(sizeText)"
        }
        return sizeText
    }

    /// 判断缩略图是否“空白”（读卡器对部分视频返回的占位封面常为纯白/透明）
    private static func isBlank(_ cgImage: CGImage) -> Bool {
        let size = 8
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return false }
        let bytes = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        for i in 0..<(size * size) {
            let o = i * 4
            let r = bytes[o]
            let g = bytes[o + 1]
            let b = bytes[o + 2]
            let a = bytes[o + 3]
            if a > 0 && !(r > 245 && g > 245 && b > 245) {
                return false
            }
        }
        return true
    }

    /// 本地生成视频封面（读卡器无法出封面时的兜底）
    private func generateLocalVideoThumbnail(for file: CameraFile) {
        let key = file.id
        guard !localThumbnailJobs.contains(key) else { return }
        localThumbnailJobs.insert(key)
        loadVideoURL(for: file) { [weak self] url in
            guard let self, let url else { return }
            Self.extractVideoThumbnail(from: url) { cgImage in
                DispatchQueue.main.async {
                    if let cgImage, !Self.isBlank(cgImage) {
                        file.thumbnail = cgImage
                    }
                }
            }
        }
    }

    /// 从视频提取首帧作为封面
    private static func extractVideoThumbnail(from url: URL, completion: @escaping (CGImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 600, height: 600)
            let time = CMTime(seconds: 0, preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
                completion(cg)
            } else {
                completion(nil)
            }
        }
    }

    // MARK: - 内部实现

    private func flattened(_ items: [ICCameraItem]?) -> [ICCameraItem] {
        guard let items else { return [] }
        var result: [ICCameraItem] = []
        for item in items {
            if let folder = item as? ICCameraFolder {
                result.append(contentsOf: flattened(folder.contents))
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// 延迟合并重建文件列表（枚举期间回调频繁时合并，避免频繁重排导致懒加载失效）
    private func scheduleRebuild() {
        rebuildWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rebuildFiles()
            // 目录未完整加载前始终保持“正在读取”状态，
            // 避免先显示最旧的一批、再跳成最新排序
            self.isEnumerating = !self.catalogComplete
        }
        rebuildWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    /// 兜底：若迟迟收不到“目录加载完成”回调，则强制结束枚举
    private func scheduleEnumerationTimeout() {
        enumerationTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.catalogComplete = true
            self.isEnumerating = false
            self.rebuildFiles()
        }
        enumerationTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    /// 追加已发现条目（用 Set 去重，O(1) 查找，替代 O(n²) 的 contains）
    private func addDiscovered(_ items: [ICCameraItem]) {
        for item in items {
            let key = ObjectIdentifier(item)
            if discoveredIDs.insert(key).inserted {
                discoveredItems.append(item)
            }
        }
    }

    private func rebuildFiles() {
        // 合并 camera.mediaFiles（兜底），O(n) 去重
        if let camera {
            addDiscovered(flattened(camera.mediaFiles))
        }

        let mediaItems = discoveredItems.filter { item in
            CameraFile.mediaExtensions.contains(CameraFile.pathExtension(of: item.name))
        }

        var lookup: [ObjectIdentifier: CameraFile] = [:]
        var list: [CameraFile] = []
        list.reserveCapacity(mediaItems.count)
        for item in mediaItems {
            let key = ObjectIdentifier(item)
            let file = fileLookup[key] ?? CameraFile(item: item)
            lookup[key] = file
            list.append(file)
        }

        // 文件名即拍摄顺序（DSCF#### 编号），纯字典序即可，比 localizedStandardCompare 快很多
        list.sort { a, b in
            sortOrder == .newestFirst ? a.name > b.name : a.name < b.name
        }

        fileLookup = lookup
        files = list
    }

    /// 懒加载缩略图（幂等，单元格出现时调用）
    func loadThumbnail(for file: CameraFile) {
        guard let cameraFile = file.item as? ICCameraFile else { return }
        let key = file.id
        guard !requestedThumbnails.contains(key) else { return }
        requestedThumbnails.insert(key)
        cameraFile.requestThumbnail()
    }

    /// 懒加载元数据（幂等，用于拍摄日期显示）
    func loadMetadata(for file: CameraFile) {
        let key = file.id
        guard !requestedMetadata.contains(key) else { return }
        requestedMetadata.insert(key)
        file.item.requestMetadata()
    }

    private func handleDisconnect() {
        camera = nil
        cameraName = nil
        files = []
        fileLookup = [:]
        discoveredItems = []
        discoveredIDs = []
        requestedThumbnails = []
        requestedMetadata = []
        dataCompletions = [:]
        localThumbnailJobs = []
        catalogComplete = false
        rebuildWorkItem?.cancel()
        enumerationTimeoutWorkItem?.cancel()
        isEnumerating = false
        state = .disconnected
    }

    static func writeTempFile(data: Data, fileName: String) -> URL? {
        let safeName = fileName.components(separatedBy: "/").last ?? fileName
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - ICDeviceBrowserDelegate

extension CameraManager: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let camera = device as? ICCameraDevice else { return }
            self.camera = camera
            camera.delegate = self
            self.cameraName = camera.name
            self.lastErrorMessage = nil
            self.state = .opening(camera.name ?? L10n.tr("device.camera"))
            camera.requestOpenSession()
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.camera === device else { return }
            self.handleDisconnect()
        }
    }
}

// MARK: - ICDeviceDelegate

extension CameraManager: ICDeviceDelegate {
    func didRemove(_ device: ICDevice) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.camera === device else { return }
            self.handleDisconnect()
        }
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let camera = device as? ICCameraDevice else { return }
            self.camera = camera
            self.cameraName = camera.name
            self.state = .ready
            self.isEnumerating = true
            self.scheduleRebuild()
            self.scheduleEnumerationTimeout()
        }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let error {
                self.lastErrorMessage = error.localizedDescription
                self.state = .disconnected
            } else if let camera = device as? ICCameraDevice {
                self.camera = camera
                self.cameraName = camera.name
                self.state = .ready
                self.isEnumerating = true
                self.scheduleRebuild()
                self.scheduleEnumerationTimeout()
            }
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.camera === device else { return }
            self.handleDisconnect()
        }
    }
}

// MARK: - ICCameraDeviceDelegate

extension CameraManager: ICCameraDeviceDelegate {
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.addDiscovered(self.flattened(items))
            self.isEnumerating = true
            self.scheduleRebuild()
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let flat = self.flattened(items)
            let flatIDs = Set(flat.map { ObjectIdentifier($0) })
            self.discoveredItems.removeAll { flatIDs.contains(ObjectIdentifier($0)) }
            self.discoveredIDs.subtract(flatIDs)
            self.rebuildFiles()
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let key = ObjectIdentifier(item)
            self.requestedThumbnails.remove(key)
            guard let file = self.fileLookup[key] else { return }
            if let thumbnail, !Self.isBlank(thumbnail) {
                file.thumbnail = thumbnail
            } else if file.isVideo {
                // 读卡器对部分视频无法生成封面（返回空图/nil），本地提取视频首帧兜底
                self.generateLocalVideoThumbnail(for: file)
            } else {
                file.thumbnail = thumbnail
            }
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildFiles()
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let key = ObjectIdentifier(item)
            self.fileLookup[key]?.updateDate(from: metadata)
        }
    }

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        DispatchQueue.main.async { [weak self] in
            self?.scheduleRebuild()
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        // 暂不处理 PTP 事件
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildWorkItem?.cancel()
            self.enumerationTimeoutWorkItem?.cancel()
            self.camera = device
            self.cameraName = device.name
            self.state = .ready
            self.catalogComplete = true
            self.isEnumerating = false
            self.rebuildFiles()
        }
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        DispatchQueue.main.async { [weak self] in
            self?.scheduleRebuild()
        }
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        // 设备被锁定，媒体不可用
    }
}
