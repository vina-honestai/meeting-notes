// ============================================================
// meeting-recorder.swift — 마이크 녹음 CLI (AVAudioEngine 기반)
//
// 사용법:  meeting-recorder <출력.wav> [최대초]
//   SIGINT/SIGTERM 을 받으면 파일을 정상 마무리하고 종료한다(녹음 종료 = kill -INT).
//   출력 형식: 16kHz mono 16bit WAV  (whisper 가 바로 먹는 형식)
//   종료 시 stderr 에 `RECORDED <초> <프레임수>` 를 찍는다 — 호출한 쪽에서 손실 점검용.
//
// 빌드:  swiftc -O -o ~/bin/meeting-recorder bin/meeting-recorder.swift
//
// ------------------------------------------------------------
// 왜 ffmpeg 대신 이걸 쓰나 (2026-08-11)
//
//   ffmpeg 의 avfoundation 입력은 CoreAudio 가 넘겨준 오디오 버퍼를 '한 칸'짜리 슬롯에만
//   들고 있다. 읽기 루프가 그 버퍼를 가져가기 전에 다음 버퍼가 도착하면 앞의 것을 통째로 버린다.
//   그래서 CPU 가 놀고 있어도 조용히 소리가 빠진다.
//
//   실측: 20초 녹음 → 18.4초만 파일에 담김(약 8% 손실). 빈 자리를 무음으로 채워보면
//   106ms 짜리 덩어리가 약 1.25초마다 하나씩 사라지고 있었다. 실제 회의 녹음에서도
//   16분 23초를 녹음했는데 파일 안에는 15분 13초(70초 = 7.1% 증발)뿐이었다.
//   버퍼 큐(-thread_queue_size)를 키워도, 리샘플링을 빼도 그대로였다 — ffmpeg 옵션으로는 못 고친다.
//   빠진 자리는 그냥 이어붙기 때문에 사람이 들으면 멀쩡하지만 단어 조각이 실제로 없다.
//
//   AVAudioEngine 의 탭(tap)은 CoreAudio 가 주는 버퍼를 빠짐없이 콜백으로 넘겨준다.
// ============================================================

import AVFoundation
import Foundation

let err = FileHandle.standardError
func log(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }
func fail(_ s: String) -> Never { log("[meeting-recorder] " + s); exit(1) }

let args = CommandLine.arguments
guard args.count >= 2 else { log("사용법: meeting-recorder <출력.wav> [최대초]"); exit(2) }
let url = URL(fileURLWithPath: args[1])
let maxSeconds: Double? = args.count >= 3 ? Double(args[2]) : nil

let engine = AVAudioEngine()
let input = engine.inputNode
let inputFormat = input.outputFormat(forBus: 0)
guard inputFormat.sampleRate > 0 else { fail("마이크를 열 수 없습니다(입력 장치·권한 확인).") }

let outSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 16000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
]

var file: AVAudioFile?
do { file = try AVAudioFile(forWriting: url, settings: outSettings) }
catch { fail("파일을 만들 수 없습니다: \(url.path) — \(error.localizedDescription)") }
let outFormat = file!.processingFormat

guard let converter = AVAudioConverter(from: inputFormat, to: outFormat) else {
    fail("오디오 변환기를 만들 수 없습니다(\(inputFormat.sampleRate)Hz → 16000Hz).")
}

// 탭 콜백(오디오 스레드)과 종료 처리(메인 스레드)가 같은 파일을 만지므로 잠금이 필요하다.
let lock = NSLock()
var written: Int64 = 0
var convertErrors = 0

let ratio = outFormat.sampleRate / inputFormat.sampleRate
input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
    guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

    // 이 콜백이 준 버퍼 하나만 먹이고, 그 다음엔 '지금은 없음'을 알려 변환기를 비운다.
    var supplied = false
    var convErr: NSError?
    converter.convert(to: out, error: &convErr) { _, status in
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
    if convErr != nil { convertErrors += 1; return }
    guard out.frameLength > 0 else { return }

    lock.lock()
    defer { lock.unlock() }
    guard let f = file else { return }          // 이미 종료 처리됨
    do { try f.write(from: out); written += Int64(out.frameLength) }
    catch { convertErrors += 1 }
}

// ---------- 종료 처리 ----------
var finished = false
func finish() {
    guard !finished else { return }
    finished = true
    engine.stop()
    input.removeTap(onBus: 0)
    lock.lock()
    file = nil                                   // 닫히면서 WAV 헤더 길이가 확정된다
    lock.unlock()
    let secs = Double(written) / outFormat.sampleRate
    if convertErrors > 0 { log("[meeting-recorder] 경고: 쓰기/변환 실패 \(convertErrors)회") }
    log(String(format: "RECORDED %.2f %d", secs, written))
    exit(0)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigint.setEventHandler { finish() }
sigterm.setEventHandler { finish() }
sigint.resume()
sigterm.resume()

engine.prepare()
do { try engine.start() }
catch { fail("녹음을 시작할 수 없습니다 — \(error.localizedDescription)") }

log("[meeting-recorder] 녹음 시작: \(url.path) (입력 \(Int(inputFormat.sampleRate))Hz \(inputFormat.channelCount)ch → 16000Hz mono)")

if let cap = maxSeconds {
    DispatchQueue.main.asyncAfter(deadline: .now() + cap) { finish() }
}

dispatchMain()
