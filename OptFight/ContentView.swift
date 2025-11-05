//
//  ContentView.swift
//  OptFight
//
//  Created by 陳慶儒 on 2025/10/13.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject var auth = GameCenterAuth.shared
    @StateObject var matchSvc = MatchService()
    @State private var myAnswer: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(auth.isAuthenticated ? "Game Center ✅" : "尚未登入").font(.headline)

            HStack {
                Button("登入/檢查") {
                    auth.authenticate()
                }
                Button("配對(2人)") { matchSvc.presentMatchmaker() }
                    .disabled(!auth.isAuthenticated)
            }

            Divider().padding(.vertical, 8)

            Text("第\(max(matchSvc.roundIndex, 0))題")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(matchSvc.currentQuestion)
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                matchSvc.buzz()
            } label: {
                Text(matchSvc.lockedBy == nil ? "搶答" :
                     (matchSvc.lockedBy == matchSvc.myId ? "你搶到作答權" : "對手已搶到"))
                    .font(.system(size: 28, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(matchSvc.lockedBy == nil ? .blue : .gray)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
            }
            .disabled(matchSvc.match == nil || matchSvc.lockedBy != nil)

            if matchSvc.lockedBy == matchSvc.myId {
                HStack {
                    TextField("輸入答案…", text: $myAnswer)
                        .textFieldStyle(.roundedBorder)
                    Button("送出") {
                        matchSvc.sendAnswer(myAnswer)
                        myAnswer = ""
                    }.buttonStyle(.borderedProminent)
                }.padding(.horizontal)
            }

            List(matchSvc.log, id: \.self) { Text($0).font(.caption) }
        }
        .padding()
        // 改為在 scene 變成 active 時檢查/觸發認證，避免過早 present
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                auth.authenticate()
            }
        }
        // 可保留首次出現時的嘗試，但不強制；若想更穩定可以移除 onAppear 僅靠 scenePhase
        .onAppear {
            // 輕微延遲，確保 window stack 準備好
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                auth.authenticate()
            }
        }
    }
}

#Preview {
    ContentView()
}
