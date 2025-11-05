//
//  MatchService.swift
//  OptFight
//

import Foundation
import Combine
@preconcurrency import GameKit        // 降噪 GameKit 並發標註
#if canImport(UIKit)
import UIKit
#endif

// 用來在 @Sendable 閉包中安全攜帶非 Sendable 類型（GKMatch / UIViewController）
struct SendableBox<T>: @unchecked Sendable { let value: T }

// 取得最上層可呈現的 VC（顯示配對 UI 等）
private func topViewController() -> UIViewController? {
    #if canImport(UIKit)
    guard let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }),
          let window = scene.windows.first(where: { $0.isKeyWindow }),
          var top = window.rootViewController else { return nil }
    while let presented = top.presentedViewController { top = presented }
    return top
    #else
    return nil
    #endif
}

final class MatchService: NSObject, ObservableObject {
    // Published 狀態（MainActor 隔離）
    @Published var match: GKMatch?
    @Published var isHost = false
    @Published var myId: String = GKLocalPlayer.local.gamePlayerID
    @Published var lockedBy: String? = nil
    @Published var roundIndex = 0
    @Published var log: [String] = []
    @Published var currentQuestion: String = "等待配對…"

    // 私有狀態
    private var currentAnswer: String = ""
    // 僅存 playerID，避免 GKPlayer 的 Sendable 抱怨
    private var players: [String] = []
    private var pendingCancelTimer: DispatchWorkItem?

    // MARK: - Matchmaking（帶官方 UI）
    func presentMatchmaker() {
        let req = GKMatchRequest()
        req.minPlayers = 2
        req.maxPlayers = 2
        //req.playerGroup = 20251013

        guard let mmvc = GKMatchmakerViewController(matchRequest: req) else {
            append("無法建立 GKMatchmakerViewController")
            return
        }
        mmvc.matchmakerDelegate = self
        append("開啟配對 UI，group=\(req.playerGroup) players=\(req.minPlayers)-\(req.maxPlayers)")

        if let root = topViewController() {
            root.present(mmvc, animated: true)
        } else {
            append("找不到 rootViewController，無法顯示配對 UI")
        }
    }

    // MARK: - Matchmaking（程式式）
    func presentMatchmakerProgrammatic(timeout: TimeInterval = 20) {
        let req = GKMatchRequest()
        req.minPlayers = 2
        req.maxPlayers = 2
        //req.playerGroup = 20251013

        append("程式式配對開始，group=\(req.playerGroup) players=\(req.minPlayers)-\(req.maxPlayers) timeout=\(Int(timeout))s")

        GKMatchmaker.shared().cancel()           // 取消舊請求
        pendingCancelTimer?.cancel()
        let cancelItem = DispatchWorkItem { [weak self] in
            self?.append("配對逾時，取消中…")
            GKMatchmaker.shared().cancel()
        }
        pendingCancelTimer = cancelItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: cancelItem)

        GKMatchmaker.shared().findMatch(for: req) { [weak self] newMatch, error in
            guard let self else { return }
            self.pendingCancelTimer?.cancel()
            self.pendingCancelTimer = nil

            if let error = error as NSError? {
                self.append("程式式配對錯誤：\(error.localizedDescription) (code=\(error.code), domain=\(error.domain))")
                return
            }
            guard let newMatch else {
                self.append("程式式配對回傳 match=nil（可能被取消或逾時）")
                return
            }

            // 用 Box 攜帶 GKMatch 進主緒，避免 @Sendable 捕捉非 Sendable
            let mbox = SendableBox(value: newMatch)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let m = mbox.value
                self.match = m
                m.delegate = self
                self.append("程式式配對成功，等待玩家連線")
            }
        }
    }

    func cancelPendingMatch() {
        pendingCancelTimer?.cancel()
        pendingCancelTimer = nil
        GKMatchmaker.shared().cancel()
        append("已取消配對請求")
    }

    // MARK: - 回合流程
    func startRound() {
        guard isHost else {
            append("非 Host，忽略 startRound()")
            return
        }

        DispatchQueue.main.async {
            self.lockedBy = nil
            self.roundIndex += 1
        }

        let qa: [(String,String)] = [
            ("Snellen E 視標的開口朝哪？", "右"),
            ("近視是眼球光學為？", "焦點在視網膜前"),
            ("JCC測試主要調整的是？", "散光軸位與度數")
        ]
        let idx = max(self.roundIndex, 1) - 1
        let pick = qa[idx % qa.count]

        DispatchQueue.main.async {
            self.currentQuestion = pick.0
            self.currentAnswer = pick.1
        }

        broadcast(.startRound(round: max(self.roundIndex, 1), question: pick.0, thinkMs: 3000, answer: pick.1))
        append("Round \(self.roundIndex) 開始，題目：\(pick.0)")
    }

    func buzz() {
        guard lockedBy == nil else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        broadcast(.buzz(playerId: myId, clientEpochMs: now), mode: .unreliable)
        append("送出搶答")
    }

    func sendAnswer(_ text: String) {
        guard lockedBy == myId else { return }
        broadcast(.answer(playerId: myId, text: text))
        if isHost {
            let correct = (text == currentAnswer)
            broadcast(.judge(correct: correct, scoreDelta: correct ? 1 : 0))
            startRound()
        }
    }

    // MARK: - 共用工具
    fileprivate func append(_ s: String) {
        DispatchQueue.main.async { self.log.append(s) }
    }

    fileprivate func decideHost() {
        let ids = ([myId] + players).sorted()
        let newIsHost = (ids.first == myId)
        DispatchQueue.main.async { self.isHost = newIsHost }
        append("決定身分：myId=\(myId), ids=\(ids), 玩家數=\(players.count) -> \(newIsHost ? "Host" : "Client")")
    }

    fileprivate func broadcast(_ msg: NetMsg, mode: GKMatch.SendDataMode = .reliable) {
        guard let match else { return }
        do {
            try match.sendData(toAllPlayers: encode(msg), with: mode)
            append("已送出訊息：\(msg)")
        } catch {
            append("send error \(error.localizedDescription)")
        }
    }

    fileprivate func handleIncoming(_ msg: NetMsg) {
        switch msg {
        case .hello(let name, let hostFlag):
            append("hello from \(name) host?\(hostFlag)")

        case .startRound(let r, let q, _, let ans):
            DispatchQueue.main.async {
                self.roundIndex = r
                self.currentQuestion = q
                self.currentAnswer = ans
                self.lockedBy = nil
            }
            append("收到題目：\(q)")

        case .buzz(let pid, _):
            if isHost && lockedBy == nil {
                DispatchQueue.main.async { self.lockedBy = pid }
                broadcast(.lock(winnerId: pid))
                append("鎖定搶答：\(pid)")
            }

        case .lock(let winnerId):
            DispatchQueue.main.async { self.lockedBy = winnerId }
            append(winnerId == myId ? "你搶到作答權" : "對手搶到作答權")

        case .answer(_, let text):
            append("收到答案：\(text)")

        case .judge(let correct, let delta):
            append("判定：\(correct ? "正確" : "錯誤") +\(delta)")
        }
    }
}

// MARK: - GKMatchDelegate（nonisolated；內部用主緒更新）
nonisolated extension MatchService: GKMatchDelegate {
    func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        // 解析與狀態更新放到主緒
        let dbox = SendableBox(value: data)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let msg = decode(dbox.value) else {
                self.append("收到無法解碼的資料，長度=\(dbox.value.count)")
                return
            }
            self.append("收到訊息：\(msg)")
            self.handleIncoming(msg)
        }
    }

    func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        // 先取出值類型，避免捕捉 GKPlayer
        let pid = player.gamePlayerID
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch state {
            case .connected:
                self.players.append(pid)
                self.append("玩家連線：\(pid)")
                self.decideHost()
                self.broadcast(.hello(playerName: GKLocalPlayer.local.displayName, isHost: self.isHost))
                if self.isHost {
                    self.append("我是 Host，準備開始回合")
                    self.startRound()
                } else {
                    self.append("我是 Client，等待題目")
                }
            case .disconnected:
                self.append("對手離線，結束本局")
            default:
                break
            }
        }
    }

    func match(_ match: GKMatch, didFailWithError error: Error?) {
        let msg = error?.localizedDescription ?? "unknown"
        DispatchQueue.main.async { [weak self] in
            self?.append("Match錯誤：\(msg)")
        }
    }
}

// MARK: - GKMatchmakerViewControllerDelegate（nonisolated；用 Box 帶物件回主緒）
nonisolated extension MatchService: GKMatchmakerViewControllerDelegate {
    func matchmakerViewControllerWasCancelled(_ viewController: GKMatchmakerViewController) {
        let vcbox = SendableBox(value: viewController)
        DispatchQueue.main.async { [weak self] in
            vcbox.value.dismiss(animated: true)
            self?.append("使用者取消配對")
        }
    }

    func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFailWithError error: Error) {
        let vcbox = SendableBox(value: viewController)
        let msg = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            vcbox.value.dismiss(animated: true)
            self?.append("配對錯誤：\(msg)")
        }
    }

    func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFind match: GKMatch) {
        // 將 GKMatch / VC 都包裝成可在 @Sendable 閉包中攜帶的 Box
        let mbox = SendableBox(value: match)
        let vcbox = SendableBox(value: viewController)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let m = mbox.value
            self.match = m
            m.delegate = self
            self.append("找到 Match，等待玩家連線")
            vcbox.value.dismiss(animated: true)
        }
    }
}
