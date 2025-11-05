//
//  Untitled.swift
//  OptFight
//
//  Created by 陳慶儒 on 2025/10/13.
//

// GameCenterAuth.swift / MatchService.swift
import Foundation
import Combine
import GameKit
#if canImport(UIKit)
import UIKit
#endif

final class GameCenterAuth: NSObject, ObservableObject {
    static let shared = GameCenterAuth()
    @Published var isAuthenticated = false

    // 取得目前可用的最上層 UIViewController
    #if canImport(UIKit)
    private func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        else { return nil }

        // 在多 window 情境下，優先選 keyWindow 或 isKeyWindow
        let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
    #endif

    func authenticate() {
        // 保證在主執行緒處理 UI
        DispatchQueue.main.async {
            GKLocalPlayer.local.authenticateHandler = { [weak self] vc, error in
                guard let self else { return }

                if let error {
                    print("GC auth error:", error.localizedDescription)
                }

                #if canImport(UIKit)
                if let vc {
                    // 可能在 App 剛啟動時 topVC 尚未可用，重試一次
                    if let presenter = self.topViewController() {
                        presenter.present(vc, animated: true)
                    } else {
                        // 延遲一點點再試，避免視窗尚未建立
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                            guard let self, let presenter = self.topViewController() else { return }
                            presenter.present(vc, animated: true)
                        }
                    }
                } else {
                    // 沒有 vc 代表系統不需要顯示登入 UI（可能已登入或無需互動）
                    self.isAuthenticated = GKLocalPlayer.local.isAuthenticated

                    // 設定並顯示 GKAccessPoint
                    let ap = GKAccessPoint.shared
                    ap.location = .topLeading
                    ap.showHighlights = true
                    ap.isActive = true
                }
                #else
                // 非 UIKit 平台（如 macOS Catalyst 以外）不嘗試 present
                self.isAuthenticated = GKLocalPlayer.local.isAuthenticated
                #endif
            }
        }
    }
}
