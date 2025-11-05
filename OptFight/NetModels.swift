//
//  NetModels.swift
//  OptFight
//
//  Created by 陳慶儒 on 2025/10/13.
//

import Foundation

enum NetMsg: Codable {
    case hello(playerName: String, isHost: Bool)
    case startRound(round: Int, question: String, thinkMs: Int, answer: String) // MVP: 送正解字串
    case buzz(playerId: String, clientEpochMs: Int64)
    case lock(winnerId: String)
    case answer(playerId: String, text: String)
    case judge(correct: Bool, scoreDelta: Int)
}

func encode(_ msg: NetMsg) -> Data { (try? JSONEncoder().encode(msg)) ?? Data() }
func decode(_ data: Data) -> NetMsg? { try? JSONDecoder().decode(NetMsg.self, from: data) }
