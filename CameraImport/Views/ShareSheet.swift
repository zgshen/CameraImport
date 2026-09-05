//
//  ShareSheet.swift
//  CameraImport
//
//  Created by Sylvan on 9/3/26.
//

import SwiftUI
import UIKit

/// 调用系统分享面板（与其它图片编辑应用一致的分享逻辑）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)

        // iPad 上分享面板需要指定 popover 锚点，否则会崩溃
        if let popover = controller.popoverPresentationController {
            let keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow })
            if let window = keyWindow {
                popover.sourceView = window.rootViewController?.view
                popover.sourceRect = CGRect(
                    x: window.bounds.midX,
                    y: window.bounds.midY,
                    width: 1,
                    height: 1
                )
            }
        }

        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
