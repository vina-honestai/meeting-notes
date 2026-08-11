// ============================================================
// meeting-rec-indicator.swift — 회의 녹음/전사 메뉴바 표시기
//
// 하는 일: 지금 무슨 작업이 돌고 있는지 메뉴바에 계속 보여준다.
//
//   ⏺ 12:34         녹음 중       (빨간 아이콘 점멸 + 경과시간)
//   〰 전사 42%       받아쓰기 중   (whisper 가 오디오의 몇 %까지 왔는지)
//   📄 회의록 작성 중  마무리 중     (Claude 가 회의록 정리)
//   ✓ 회의록 완료     완료 후 8초 표시하고 스스로 사라짐
//
// 상태 판단 — 파일 두 개만 본다 (tb-record-toggle.sh 가 만든다):
//   .tb-rec/state        <ffmpeg pid>|<녹음파일>|<시작 epoch>
//   .tb-rec/transcribing <작업 pid>|<작업로그 경로>|<시작 epoch>|<녹음 길이 초>
//   둘 다 없거나 pid 가 죽어 있으면 스스로 종료한다.
//   → 비정상 종료돼도 '녹음 중' 이라고 거짓말하는 아이콘이 남지 않는다.
//   → 반대로 이 표시기가 죽어도 녹음·전사는 영향받지 않는다(표시 전용).
//
// 진행률: 작업로그 끝부분에서 whisper 가 마지막으로 뱉은 구간의 끝시각을 읽어
//        녹음 길이로 나눈다. (로그 예: [00:00:29.820 --> 00:00:33.880]  텍스트)
//
// 디버그: MRI_DEBUG=1 로 실행하면 매 초 상태를 stderr 에 찍는다.
// 빌드:   swiftc -O -o ~/bin/meeting-rec-indicator ~/bin/meeting-rec-indicator.swift
// ============================================================

import Cocoa

let home = FileManager.default.homeDirectoryForCurrentUser.path
let baseDir = "\(home)/Desktop/meeting-notes"
let stateDir = "\(baseDir)/.tb-rec"
let statePath = "\(stateDir)/state"
let transcribingPath = "\(stateDir)/transcribing"
let togglePath = "\(baseDir)/bin/tb-record-toggle.sh"
let minutesDir = "\(baseDir)/minutes"

/// `a|b|c` 형식 상태파일을 칸 단위로 읽는다. 파일이 없으면 nil.
func fields(of path: String) -> [String]? {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed.components(separatedBy: "|")
}

/// 살아있는 pid 인지 확인 (signal 0 = 존재 여부만 검사)
func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

/// 큰 로그를 매초 통째로 읽지 않도록 끝부분만 읽는다.
func tail(of path: String, bytes: Int = 32_768) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    let from = size > UInt64(bytes) ? size - UInt64(bytes) : 0
    try? fh.seek(toOffset: from)
    guard let data = try? fh.readToEnd() else { return nil }
    return String(decoding: data, as: UTF8.self)
}

enum Phase {
    case recording(start: TimeInterval)
    case transcribing(log: String, totalSeconds: Double, since: TimeInterval)
    case finished
    case settling          // 단계 전환 중(녹음 종료 ~ 전사 시작 사이의 짧은 공백)
}

enum MenuKind { case recording, transcribing, finished, settling }

final class Indicator: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    // ⚠ 메뉴는 '한 번만' 만들고 항목의 표시/숨김만 바꾼다.
    //    NSMenuItem 은 동시에 두 메뉴에 속할 수 없어서, 단계마다 메뉴를 새로 만들며
    //    같은 항목을 재사용하면 NSInternalInconsistencyException 이 난다.
    //    ("Item to be inserted into menu already is in another menu")
    //    그 예외가 타이머 콜백을 죽여 표시가 특정 상태에서 멈추는 버그가 있었다.
    private let menu = NSMenu()
    private let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var stopItem: NSMenuItem!
    private var logItem: NSMenuItem!
    private var minutesItem: NSMenuItem!

    private var phase: Phase = .settling
    private var menuKind: MenuKind?
    private var lit = true                 // 점멸 상태
    private var sawTranscribing = false    // 전사 단계를 거쳤는가(완료 표시 여부 판단)
    private var idleTicks = 0              // 상태파일이 둘 다 없는 상태가 몇 초 이어졌나
    private var finishedTicks = 0
    private var currentLog: String?
    private let debug = ProcessInfo.processInfo.environment["MRI_DEBUG"] != nil

    // App Nap 차단용 토큰 — 반드시 붙잡고 있어야 효력이 유지된다.
    // 이게 없으면 macOS 가 '창 없는 백그라운드 앱'으로 보고 타이머를 재운다.
    private var activityToken: NSObjectProtocol?

    // 미리 만들어 둔 아이콘들
    private lazy var recLit = symbol("record.circle", color: .systemRed)
    private lazy var recDim = symbol("record.circle", color: NSColor.systemRed.withAlphaComponent(0.18))
    private lazy var wave   = symbol("waveform")
    private lazy var doc    = symbol("doc.text")
    private lazy var check  = symbol("checkmark.circle.fill", color: .systemGreen)
    private lazy var hourGl = symbol("hourglass")

    override init() {
        super.init()
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated, reason: "회의 녹음 상태 표시")
        setupMenu()
        poll()                                   // 첫 상태를 즉시 반영

        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lit.toggle()
            self.render()
        }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    // MARK: - 메뉴 (한 번만 구성)

    private func setupMenu() {
        stopItem    = makeItem("녹음 종료하고 회의록 만들기", #selector(stopRecording))
        logItem     = makeItem("작업 로그 열기", #selector(openLog))
        minutesItem = makeItem("회의록 폴더 열기", #selector(openMinutes))
        menu.addItem(header)                    // action 이 nil 이라 자동 비활성(정보 표시용)
        menu.addItem(.separator())
        menu.addItem(stopItem)
        menu.addItem(logItem)
        menu.addItem(minutesItem)
        item.menu = menu
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        return mi
    }

    private func updateMenu(_ kind: MenuKind) {
        guard menuKind != kind else { return }
        menuKind = kind
        stopItem.isHidden    = kind != .recording
        logItem.isHidden     = kind != .transcribing
        minutesItem.isHidden = !(kind == .transcribing || kind == .finished)
    }

    // MARK: - 아이콘

    /// color 를 주면 그 색으로 고정, 안 주면 템플릿(메뉴바 밝기에 맞춰 자동 반전)
    private func symbol(_ name: String, color: NSColor? = nil, size: CGFloat = 12) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        if let color {
            let img = base.withSymbolConfiguration(
                cfg.applying(NSImage.SymbolConfiguration(paletteColors: [color])))
            img?.isTemplate = false
            return img
        }
        let img = base.withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }

    // MARK: - 상태 폴링

    private func poll() {
        if debug {
            fputs("[poll] idle=\(idleTicks) fin=\(finishedTicks) sawTr=\(sawTranscribing)\n", stderr)
        }

        // 1) 녹음 중?
        if let f = fields(of: statePath), f.count >= 3,
           let pid = pid_t(f[0]), let start = TimeInterval(f[2]), alive(pid) {
            phase = .recording(start: start)
            idleTicks = 0
            updateMenu(.recording)
            render()
            return
        }

        // 2) 전사 중?
        if let f = fields(of: transcribingPath), f.count >= 4,
           let pid = pid_t(f[0]), let total = Double(f[3]), alive(pid) {
            sawTranscribing = true
            currentLog = f[1]
            let since = TimeInterval(f[2]) ?? Date().timeIntervalSince1970
            phase = .transcribing(log: f[1], totalSeconds: max(total, 1), since: since)
            idleTicks = 0
            updateMenu(.transcribing)
            render()
            return
        }

        // 3) 둘 다 없음 — 전사를 거쳤으면 '완료'를 잠시 보여주고 종료
        if sawTranscribing {
            phase = .finished
            updateMenu(.finished)
            render()
            finishedTicks += 1
            if finishedTicks >= 8 { quit() }
            return
        }

        // 녹음 종료 ~ 전사 시작 사이의 공백일 수 있으니 잠시 기다린다
        phase = .settling
        updateMenu(.settling)
        render()
        idleTicks += 1
        if idleTicks >= 12 { quit() }
    }

    /// NSApplication.terminate 는 이 형태(창 없는 accessory 앱, 델리게이트 없음)에서
    /// 실제로 종료되지 않는 경우가 확인됨 → 저장할 상태가 없으므로 즉시 종료한다.
    private func quit() -> Never {
        NSStatusBar.system.removeStatusItem(item)   // 메뉴바에서 먼저 지우고
        exit(0)
    }

    // MARK: - 로그에서 진행률 뽑기

    /// 반환: 메뉴바에 표시할 문구
    ///
    /// %가 항상 나오지는 않는다. whisper 는 출력이 파일로 리디렉트되면 stdout 을
    /// 블록 버퍼링(약 4KB)해서, 짧은 녹음은 끝날 때까지 구간 줄이 한 줄도 안 나온다.
    /// (긴 회의는 버퍼가 차면서 주기적으로 나온다 — 정작 %가 필요한 쪽은 긴 회의다.)
    /// 그래서 % 를 못 구하면 '전사 중 M:SS' 로 경과시간을 보여준다 — 최소한
    /// 작업이 살아서 진행 중이라는 건 항상 알 수 있다.
    private func progressLabel(logPath: String, total: Double, since: TimeInterval) -> String {
        let running = "전사 중 " + hms(max(0, Int(Date().timeIntervalSince1970 - since)))
        guard let text = tail(of: logPath) else { return running }

        // 마지막 단계 표시가 3/3 이면 회의록 작성 단계
        if text.contains("3/3") { return "회의록 작성 중" }

        // whisper 구간 줄의 '끝시각' 중 마지막 것 → 오디오의 어디까지 왔는지
        let pattern = #"-->\s+(\d{2}):(\d{2}):(\d{2})\.\d{3}\]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return running }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return running }
        let h = Double(ns.substring(with: last.range(at: 1))) ?? 0
        let m = Double(ns.substring(with: last.range(at: 2))) ?? 0
        let s = Double(ns.substring(with: last.range(at: 3))) ?? 0
        let ratio = min(max((h * 3600 + m * 60 + s) / total, 0), 1)
        return String(format: "전사 %d%%", Int(ratio * 100))
    }

    private func hms(_ seconds: Int) -> String {
        let (h, m, s) = (seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    // MARK: - 그리기

    private func render() {
        guard let button = item.button else { return }
        var image: NSImage?
        var text: String

        switch phase {
        case .recording(let start):
            text = hms(max(0, Int(Date().timeIntervalSince1970 - start)))
            image = lit ? recLit : recDim         // 녹음 중일 때만 점멸
            header.title = "녹음 중 · \(text)"

        case .transcribing(let log, let total, let since):
            text = progressLabel(logPath: log, total: total, since: since)
            image = text.hasPrefix("회의록") ? doc : wave
            header.title = text

        case .finished:
            text = "회의록 완료"
            image = check
            header.title = text

        case .settling:
            text = "마무리 중"
            image = hourGl
            header.title = text
        }

        button.image = image
        button.imagePosition = .imageLeading
        // 글자는 점멸시키지 않는다 — 색을 고정해 아이콘만 깜빡이게
        button.attributedTitle = NSAttributedString(
            string: " " + text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
    }

    // MARK: - 메뉴 동작

    /// 토글 스크립트를 그대로 호출 = 터치바를 다시 누른 것과 동일한 동작.
    /// nohup 으로 띄워 이 표시기가 종료돼도 전사가 계속되게 한다.
    @objc private func stopRecording() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "nohup '\(togglePath)' >/dev/null 2>&1 &"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:\(home)/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        task.environment = env
        try? task.run()
        // 종료 판단은 poll() 에 맡긴다 (state 가 사라지면 자동으로 다음 단계로)
    }

    @objc private func openLog() {
        guard let log = currentLog else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: log))
    }

    @objc private func openMinutes() {
        NSWorkspace.shared.open(URL(fileURLWithPath: minutesDir))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)      // Dock·앱 전환기에 안 뜨는 메뉴바 전용 앱
let indicator = Indicator()
app.run()
