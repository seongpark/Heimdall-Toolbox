// Heimdall Toolbox — Heimdall(Odin 프로토콜) + ADB 올인원 macOS 앱
// 빌드: ./build.sh  (Contents/Resources/bin 안의 adb, fastboot, heimdall, lz4 를 사용)

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - App

@main
struct HeimdallToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var runner = Runner()

    var body: some Scene {
        WindowGroup("Heimdall Toolbox") {
            ContentView()
                .environmentObject(runner)
                .frame(minWidth: 1040, minHeight: 680)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // 번들 안의 adb 서버를 정리
        guard let res = Bundle.main.resourceURL else { return }
        let p = Process()
        p.executableURL = res.appendingPathComponent("bin/adb")
        p.arguments = ["kill-server"]
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: - Process runner

final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func add(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

func shq(_ s: String) -> String {
    (s.isEmpty || s.contains(" ")) ? "'\(s)'" : s
}

@MainActor
final class Runner: ObservableObject {
    @Published private(set) var log = ""
    @Published var progress = ""
    @Published private(set) var busy = false

    private var active = 0 { didSet { busy = active > 0 } }
    private var current: Process?

    let binDir: URL = (Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")).appendingPathComponent("bin")

    func path(_ tool: String) -> String {
        tool.hasPrefix("/") ? tool : binDir.appendingPathComponent(tool).path
    }

    func append(_ s: String) {
        log += s
        if log.utf8.count > 300_000 {
            log = "…(이전 로그 생략)…\n" + String(log.suffix(200_000))
        }
    }

    func clear() { log = ""; progress = "" }

    func stop() {
        guard let p = current, p.isRunning else { return }
        p.terminate()
        append("\n[중지 요청됨]\n")
    }

    /// \r, \b 로 갱신되는 진행률 출력은 상태줄에, 나머지는 로그에
    private func handleChunk(_ text: String) {
        if text.contains("\r") || text.contains("\u{8}") {
            let segs = text.components(separatedBy: CharacterSet(charactersIn: "\r\u{8}"))
            for s in segs where s.contains("\n") { append(s) }
            if let last = segs.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                progress = last.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            append(text)
        }
    }

    @discardableResult
    func run(_ tool: String, _ args: [String], captureOnly: Bool = false) async -> (code: Int32, output: String) {
        append("\n$ \((tool as NSString).lastPathComponent) \(args.map(shq).joined(separator: " "))\n")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path(tool))
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = binDir.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let box = OutputBox()
        let h = pipe.fileHandleForReading

        h.readabilityHandler = { fh in
            let d = fh.availableData
            guard !d.isEmpty else { return }
            box.add(d)
            if !captureOnly {
                let s = String(decoding: d, as: UTF8.self)
                Task { @MainActor in self.handleChunk(s) }
            }
        }

        active += 1
        current = p
        defer {
            active -= 1
            current = nil
            progress = ""
        }

        let code: Int32 = await withCheckedContinuation { cont in
            p.terminationHandler = { proc in
                h.readabilityHandler = nil
                if let rest = try? h.readToEnd(), !rest.isEmpty {
                    box.add(rest)
                    if !captureOnly {
                        let s = String(decoding: rest, as: UTF8.self)
                        Task { @MainActor in self.handleChunk(s) }
                    }
                }
                cont.resume(returning: proc.terminationStatus)
            }
            do {
                try p.run()
            } catch {
                h.readabilityHandler = nil
                let msg = error.localizedDescription
                Task { @MainActor in self.append("실행 실패: \(msg)\n") }
                cont.resume(returning: -1)
            }
        }

        let out = box.string
        if code != 0 {
            if captureOnly { append(out) }
            append("[종료 코드 \(code)]\n")
        }
        return (code, out)
    }
}

// MARK: - View-local state
// 최신 SDK의 @State는 매크로라 명령줄 swiftc에서 플러그인을 못 찾는 경우가 있어
// @StateObject 기반의 동일한 래퍼를 사용합니다.

final class StateBox<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}

@propertyWrapper
struct Local<T>: DynamicProperty {
    @StateObject private var box: StateBox<T>

    init(wrappedValue: T) {
        _box = StateObject(wrappedValue: StateBox(wrappedValue))
    }

    var wrappedValue: T {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<T> { $box.value }
}

// MARK: - Helpers

@MainActor
func pickFiles(multiple: Bool, exts: [String]) -> [URL] {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = multiple
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    if !exts.isEmpty {
        panel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
    }
    return panel.runModal() == .OK ? panel.urls : []
}

@MainActor
func confirm(_ title: String, _ message: String) -> Bool {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    a.alertStyle = .warning
    a.addButton(withTitle: "진행")
    a.addButton(withTitle: "취소")
    return a.runModal() == .alertFirstButtonReturn
}

final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []
    func add(_ u: URL) { lock.lock(); items.append(u); lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return items }
}

@MainActor
func loadDropped(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
    let box = URLBox()
    let group = DispatchGroup()
    for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let u = item as? URL {
                box.add(u)
            } else if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) {
                box.add(u)
            }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let urls = box.all
        Task { @MainActor in done(urls) }
    }
}

func sizeString(_ u: URL) -> String {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
          let n = attrs[.size] as? NSNumber else { return "" }
    return ByteCountFormatter.string(fromByteCount: n.int64Value, countStyle: .file)
}

func allFiles(_ dir: URL) -> [URL] {
    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var out: [URL] = []
    for case let u as URL in e {
        if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append(u) }
    }
    return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

// MARK: - Root

enum MainTab: String, CaseIterable, Identifiable {
    case device = "기기"
    case apk = "APK 설치"
    case sideload = "ADB 사이드로드"
    case push = "파일 전송"
    case flash = "Odin 플래시 (Heimdall)"
    var id: Self { self }
}

struct ContentView: View {
    @EnvironmentObject var r: Runner
    @Local private var tab: MainTab = .device

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                // macOS 기본 TabView는 최신 버전에서 탭 바가 내용 위에 떠서 겹치므로 직접 구성
                Picker("", selection: $tab) {
                    ForEach(MainTab.allCases) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)

                Divider()

                // 모든 탭을 유지해 탭을 바꿔도 선택한 파일 등이 사라지지 않게 함
                ZStack {
                    page(.device) { DeviceView() }
                    page(.apk) { ApkView() }
                    page(.sideload) { SideloadView() }
                    page(.push) { PushView() }
                    page(.flash) { FlashView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .frame(minHeight: 460)

            LogPane().frame(minHeight: 140)
        }
        .task {
            await r.run("adb", ["version"])
            await r.run("heimdall", ["version"])
        }
    }

    private func page<V: View>(_ t: MainTab, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(tab == t ? 1 : 0)
            .allowsHitTesting(tab == t)
            .accessibilityHidden(tab != t)
    }
}

struct LogPane: View {
    @EnvironmentObject var r: Runner

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if r.busy { ProgressView().controlSize(.small) }
                Text(r.progress.isEmpty ? (r.busy ? "작업 중…" : "대기 중") : r.progress)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("중지") { r.stop() }.disabled(!r.busy)
                Button("로그 지우기") { r.clear() }
            }
            .padding(6)
            LogTextView(text: r.log)
        }
    }
}

struct LogTextView: NSViewRepresentable {
    let text: String
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        if let tv = sv.documentView as? NSTextView {
            tv.isEditable = false
            tv.isRichText = false
            tv.font = font
            tv.textContainerInset = NSSize(width: 6, height: 6)
        }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView else { return }
        let cur = tv.string
        guard cur != text else { return }
        if !cur.isEmpty, text.hasPrefix(cur) {
            let add = String(text.dropFirst(cur.count))
            tv.textStorage?.append(NSAttributedString(string: add, attributes: [.font: font, .foregroundColor: NSColor.textColor]))
        } else {
            tv.string = text
            tv.font = font
        }
        tv.scrollToEndOfDocument(nil)
    }
}

struct FileDropList: View {
    @Binding var files: [URL]
    var exts: [String] = []
    var hint: String
    var multiple = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .foregroundColor(.secondary)
                if files.isEmpty {
                    Text(hint).foregroundColor(.secondary)
                } else {
                    List {
                        ForEach(files, id: \.self) { u in
                            HStack {
                                Text(u.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(sizeString(u)).foregroundColor(.secondary)
                                Button {
                                    files.removeAll { $0 == u }
                                } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(4)
                }
            }
            .frame(minHeight: 140)
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                loadDropped(providers) { urls in add(urls) }
                return true
            }
            HStack {
                Button("파일 선택…") { add(pickFiles(multiple: multiple, exts: exts)) }
                Button("비우기") { files.removeAll() }.disabled(files.isEmpty)
            }
        }
    }

    private func add(_ urls: [URL]) {
        let ok = urls.filter { exts.isEmpty || exts.contains($0.pathExtension.lowercased()) }
        if multiple {
            files.append(contentsOf: ok.filter { !files.contains($0) })
        } else if let f = ok.first {
            files = [f]
        }
    }
}

// MARK: - 기기

struct DeviceView: View {
    @EnvironmentObject var r: Runner
    @Local private var shellCmd = "getprop ro.product.model"

    var body: some View {
        Form {
            Section("연결 확인") {
                HStack {
                    Button("ADB 기기 목록") { Task { await r.run("adb", ["devices", "-l"]) } }
                    Button("Fastboot 기기 목록") { Task { await r.run("fastboot", ["devices"]) } }
                    Button("Download 모드 감지 (Heimdall)") { Task { await r.run("heimdall", ["detect"]) } }
                    Button("ADB 서버 재시작") {
                        Task {
                            await r.run("adb", ["kill-server"])
                            await r.run("adb", ["start-server"])
                        }
                    }
                }
                Text("처음 연결하면 휴대폰에 'USB 디버깅 허용' 창이 뜹니다. 허용해야 목록에 'device'로 표시됩니다.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("재부팅 (ADB)") {
                HStack {
                    Button("시스템") { Task { await r.run("adb", ["reboot"]) } }
                    Button("리커버리") { Task { await r.run("adb", ["reboot", "recovery"]) } }
                    Button("Download 모드") { Task { await r.run("adb", ["reboot", "download"]) } }
                    Button("부트로더/Fastboot") { Task { await r.run("adb", ["reboot", "bootloader"]) } }
                    Button("사이드로드 모드") { Task { await r.run("adb", ["reboot", "sideload"]) } }
                }
            }
            Section("재부팅 (Fastboot)") {
                HStack {
                    Button("fastboot reboot") { Task { await r.run("fastboot", ["reboot"]) } }
                    Button("fastboot reboot recovery") { Task { await r.run("fastboot", ["reboot", "recovery"]) } }
                }
            }
            Section("ADB 셸 명령") {
                HStack {
                    TextField("예: pm list packages", text: $shellCmd)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { runShell() }
                    Button("실행") { runShell() }.disabled(shellCmd.isEmpty || r.busy)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(r.busy)
    }

    private func runShell() {
        let cmd = shellCmd
        Task { await r.run("adb", ["shell", cmd]) }
    }
}

// MARK: - APK 설치

struct ApkView: View {
    @EnvironmentObject var r: Runner
    @Local private var files: [URL] = []
    @Local private var replace = true
    @Local private var downgrade = false
    @Local private var grant = false
    @Local private var testOnly = true
    @Local private var split = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("USB 디버깅이 켜진 기기에 APK를 설치합니다 (adb install).").foregroundColor(.secondary)
            FileDropList(files: $files, exts: ["apk"], hint: "APK 파일을 여기로 끌어다 놓으세요")
            HStack(spacing: 16) {
                Toggle("재설치 허용 (-r)", isOn: $replace)
                Toggle("다운그레이드 (-d)", isOn: $downgrade)
                Toggle("모든 런타임 권한 부여 (-g)", isOn: $grant)
                Toggle("테스트(디버그) APK 허용 (-t)", isOn: $testOnly)
            }
            Toggle("선택한 파일들을 하나의 앱(분할 APK)으로 설치 (install-multiple)", isOn: $split)
            HStack {
                Spacer()
                Button("설치") { Task { await install() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(files.isEmpty || r.busy)
            }
        }
        .padding()
    }

    private func install() async {
        var opts: [String] = []
        if replace { opts.append("-r") }
        if downgrade { opts.append("-d") }
        if grant { opts.append("-g") }
        if testOnly { opts.append("-t") }
        let list = files
        if split {
            let res = await r.run("adb", ["install-multiple"] + opts + list.map(\.path))
            r.append(res.code == 0 ? "\n✅ 분할 APK 설치 완료\n" : "\n❌ 설치 실패\n")
        } else {
            var ok = 0
            for f in list {
                let res = await r.run("adb", ["install"] + opts + [f.path])
                if res.code == 0 { ok += 1 }
            }
            r.append("\n✅ \(ok)/\(list.count)개 설치 완료\n")
        }
    }
}

// MARK: - 사이드로드

struct SideloadView: View {
    @EnvironmentObject var r: Runner
    @Local private var files: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("리커버리의 'Apply update from ADB' 상태에서 ZIP(OTA 등)을 바로 전송해 설치합니다 (adb sideload).")
                .foregroundColor(.secondary)
            HStack {
                Button("리커버리로 재부팅") { Task { await r.run("adb", ["reboot", "recovery"]) } }
                Button("사이드로드 모드로 재부팅") { Task { await r.run("adb", ["reboot", "sideload"]) } }
                Button("상태 확인") { Task { await r.run("adb", ["devices", "-l"]) } }
            }
            .disabled(r.busy)
            Text("상태 확인 결과가 'sideload'로 보이면 준비된 것입니다.").font(.caption).foregroundColor(.secondary)
            FileDropList(files: $files, exts: ["zip"], hint: "사이드로드할 ZIP 파일을 끌어다 놓으세요", multiple: false)
            HStack {
                Spacer()
                Button("사이드로드 시작") {
                    guard let f = files.first else { return }
                    Task {
                        let res = await r.run("adb", ["sideload", f.path])
                        r.append(res.code == 0 ? "\n✅ 전송 완료 — 기기 화면에서 설치 결과를 확인하세요\n" : "\n❌ 사이드로드 실패\n")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(files.isEmpty || r.busy)
            }
        }
        .padding()
    }
}

// MARK: - 파일 전송

struct PushView: View {
    @EnvironmentObject var r: Runner
    @Local private var files: [URL] = []
    @Local private var target = "/sdcard/Download/"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("파일을 기기 저장소로 바로 복사합니다 (adb push).").foregroundColor(.secondary)
            FileDropList(files: $files, hint: "보낼 파일을 끌어다 놓으세요")
            HStack {
                Text("대상 폴더")
                TextField("/sdcard/Download/", text: $target).textFieldStyle(.roundedBorder)
                Menu("빠른 선택") {
                    Button("Download") { target = "/sdcard/Download/" }
                    Button("Documents") { target = "/sdcard/Documents/" }
                    Button("DCIM") { target = "/sdcard/DCIM/" }
                    Button("Music") { target = "/sdcard/Music/" }
                    Button("Movies") { target = "/sdcard/Movies/" }
                }
                .frame(width: 110)
                Button("폴더 내용 보기") { let t = target; Task { await r.run("adb", ["shell", "ls -la \(shq(t))"]) } }
                    .disabled(r.busy)
            }
            HStack {
                Spacer()
                Button("전송") {
                    var dest = target.trimmingCharacters(in: .whitespaces)
                    if !dest.hasSuffix("/") { dest += "/" }
                    let list = files.map(\.path)
                    Task {
                        let res = await r.run("adb", ["push"] + list + [dest])
                        r.append(res.code == 0 ? "\n✅ 전송 완료 → \(dest)\n" : "\n❌ 전송 실패\n")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(files.isEmpty || r.busy)
            }
        }
        .padding()
    }
}

// MARK: - Odin 플래시 (Heimdall)

struct FlashEntry: Identifiable {
    let id = UUID()
    var enabled = true
    var partition: String
    var file: URL
}

func parsePit(_ text: String) -> [String: String] {
    var map: [String: String] = [:]
    var name: String?
    for raw in text.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("Partition Name:") {
            name = String(line.dropFirst("Partition Name:".count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("Flash Filename:"), let n = name, !n.isEmpty {
            let fn = String(line.dropFirst("Flash Filename:".count)).trimmingCharacters(in: .whitespaces)
            if !fn.isEmpty && fn != "-" { map[fn.lowercased()] = n }
        }
    }
    return map
}

func guessSlot(_ fileName: String) -> String? {
    let n = fileName.uppercased()
    if n.hasPrefix("HOME_CSC") || n.hasPrefix("CSC") { return "CSC" }
    for s in ["BL", "AP", "CP", "USERDATA"] where n.hasPrefix(s + "_") { return s }
    return nil
}

struct FlashView: View {
    @EnvironmentObject var r: Runner
    @Local private var slots: [String: URL] = [:]
    @Local private var pit: URL? = nil
    @Local private var detectedPit: URL? = nil
    @Local private var entries: [FlashEntry] = []
    @Local private var unmatched: [String] = []
    @Local private var workDir: URL? = nil
    @Local private var autoReboot = true
    @Local private var resume = false
    @Local private var repartition = false

    private let slotNames = ["BL", "AP", "CP", "CSC", "USERDATA"]

    var body: some View {
        HSplitView {
            // 왼쪽: 펌웨어 슬롯 / 옵션 (창이 작아도 잘리지 않게 스크롤)
            ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                Text("펌웨어 (.tar / .tar.md5)").font(.headline)
                Text("Odin처럼 BL/AP/CP/CSC 파일을 넣으세요. 여러 파일을 한 번에 끌어다 놓으면 이름으로 자동 배치됩니다.")
                    .font(.caption).foregroundColor(.secondary)
                ForEach(slotNames, id: \.self) { s in slotRow(s) }
                HStack {
                    Text("PIT").font(.system(.body, design: .monospaced)).frame(width: 84, alignment: .leading)
                    Text(pit?.lastPathComponent ?? "자동 (CSC 안의 .pit → 없으면 기기에서 읽음)")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundColor(pit == nil ? .secondary : .primary)
                    Spacer()
                    Button("선택") { if let u = pickFiles(multiple: false, exts: ["pit"]).first { pit = u } }
                    if pit != nil { Button("✕") { pit = nil } }
                }
                Button("① 압축 풀기 + 파티션 자동 매핑") { Task { await prepare() } }
                    .disabled(slots.isEmpty || r.busy)

                Divider()
                Text("옵션").font(.headline)
                Toggle("완료 후 자동 재부팅", isOn: $autoReboot)
                Toggle("이전 세션 이어서 (--resume)", isOn: $resume)
                Toggle("리파티션 (--repartition) — 위험, 필요할 때만", isOn: $repartition)

                Divider()
                HStack {
                    Button("Download 모드 감지") { Task { await r.run("heimdall", ["detect"]) } }
                    Button("기기 PIT 보기") {
                        Task {
                            let res = await r.run("heimdall", ["print-pit", "--no-reboot"] + (resume ? ["--resume"] : []))
                            if res.code == 0 { resume = true }
                        }
                    }
                }
                .disabled(r.busy)
                Text("Download 모드: 전원+볼륨 하 (기종별 상이) 또는 '기기' 탭의 Download 모드 재부팅.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 400)
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                loadDropped(providers) { urls in
                    for u in urls {
                        if u.pathExtension.lowercased() == "pit" { pit = u }
                        else if let s = guessSlot(u.lastPathComponent) { slots[s] = u }
                    }
                }
                return true
            }

            // 오른쪽: 플래시 목록
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("플래시 목록").font(.headline)
                    Spacer()
                    Button("이미지 수동 추가…") { addManual() }
                    Button("임시 파일 정리") { cleanup() }.disabled(workDir == nil || r.busy)
                }
                List {
                    ForEach($entries) { $e in
                        HStack {
                            Toggle("", isOn: $e.enabled).labelsHidden()
                            TextField("파티션", text: $e.partition)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)
                            Text(e.file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(sizeString(e.file)).foregroundColor(.secondary)
                            Button {
                                let id = e.id
                                entries.removeAll { $0.id == id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                if !unmatched.isEmpty {
                    Text("PIT에 없어 제외된 파일: " + unmatched.joined(separator: ", "))
                        .font(.caption).foregroundColor(.orange).lineLimit(3)
                }
                HStack {
                    Text("파티션 이름은 PIT의 Partition Name과 같아야 합니다 (예: BOOT, RECOVERY, SUPER).")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("② 플래시 시작") { Task { await flash() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(entries.filter(\.enabled).isEmpty || r.busy)
                }
            }
            .padding()
            .frame(minWidth: 460)
        }
    }

    @ViewBuilder
    private func slotRow(_ s: String) -> some View {
        HStack {
            Text(s).font(.system(.body, design: .monospaced)).frame(width: 84, alignment: .leading)
            Text(slots[s]?.lastPathComponent ?? "—")
                .lineLimit(1).truncationMode(.middle)
                .foregroundColor(slots[s] == nil ? .secondary : .primary)
            Spacer()
            Button("선택") {
                if let u = pickFiles(multiple: false, exts: ["tar", "md5"]).first { slots[s] = u }
            }
            if slots[s] != nil { Button("✕") { slots[s] = nil } }
        }
    }

    private func addManual() {
        for u in pickFiles(multiple: true, exts: []) {
            var base = u.deletingPathExtension()
            if base.pathExtension.lowercased() == "img" { base = base.deletingPathExtension() }
            entries.append(FlashEntry(partition: base.lastPathComponent.uppercased(), file: u))
            if u.pathExtension.lowercased() == "lz4" {
                r.append("⚠ \(u.lastPathComponent): lz4 압축 이미지는 그대로 플래시할 수 없습니다. 펌웨어 슬롯으로 넣어 자동 해제하세요.\n")
            }
        }
    }

    private func cleanup() {
        guard let dir = workDir else { return }
        entries.removeAll { $0.file.path.hasPrefix(dir.path) }
        unmatched = []
        detectedPit = nil
        try? FileManager.default.removeItem(at: dir)
        workDir = nil
        r.append("\n🧹 임시 파일 삭제: \(dir.path)\n")
    }

    private func prepare() async {
        cleanup()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("heimdall-" + String(UUID().uuidString.prefix(8)))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            r.append("임시 폴더 생성 실패: \(error.localizedDescription)\n")
            return
        }
        workDir = dir

        for s in slotNames {
            guard let u = slots[s] else { continue }
            r.append("\n▶ \(s): \(u.lastPathComponent) 압축 해제 중… (용량에 따라 몇 분 걸릴 수 있음)\n")
            // .tar.md5 끝의 MD5 문자열 때문에 경고가 나올 수 있으나 파일은 정상 추출됩니다
            await r.run("/usr/bin/tar", ["-xvf", u.path, "-C", dir.path])
        }

        for f in allFiles(dir) where f.pathExtension.lowercased() == "lz4" {
            r.append("\n▶ lz4 해제: \(f.lastPathComponent)\n")
            await r.run("lz4", ["-d", "-f", "--rm", f.path, f.deletingPathExtension().path])
        }

        var pitText = ""
        let pitFile = pit ?? allFiles(dir).first { $0.pathExtension.lowercased() == "pit" }
        detectedPit = pitFile
        if let p = pitFile {
            r.append("\n▶ PIT 분석: \(p.lastPathComponent)\n")
            pitText = await r.run("heimdall", ["print-pit", "--file", p.path], captureOnly: true).output
        } else {
            r.append("\n▶ 펌웨어에 PIT가 없어 기기에서 읽습니다 (Download 모드 연결 필요)\n")
            let res = await r.run("heimdall", ["print-pit", "--no-reboot"] + (resume ? ["--resume"] : []), captureOnly: true)
            pitText = res.output
            if res.code == 0 { resume = true }
        }

        let map = parsePit(pitText)
        if map.isEmpty {
            r.append("⚠ PIT 정보를 읽지 못했습니다. '이미지 수동 추가'로 파티션을 직접 지정하세요.\n")
        }

        var newEntries: [FlashEntry] = []
        var skipped: [String] = []
        for f in allFiles(dir) {
            let ext = f.pathExtension.lowercased()
            if ext == "pit" || ext == "lz4" || f.path.contains("/meta-data/") { continue }
            if let part = map[f.lastPathComponent.lowercased()] {
                newEntries.append(FlashEntry(partition: part, file: f))
            } else {
                skipped.append(f.lastPathComponent)
            }
        }
        entries.append(contentsOf: newEntries)
        unmatched = skipped
        r.append("\n✔ 매핑 \(newEntries.count)개 / 제외 \(skipped.count)개 — 목록을 확인한 뒤 ② 플래시 시작\n")
    }

    private func flash() async {
        let sel = entries.filter { $0.enabled && !$0.partition.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !sel.isEmpty else { return }
        let list = sel.map { "\($0.partition) ← \($0.file.lastPathComponent)" }.joined(separator: "\n")
        guard confirm("플래시를 진행할까요?",
                      "기기가 Download 모드로 연결되어 있어야 합니다. 진행 중에는 케이블을 뽑지 마세요.\n\n" + list) else { return }

        var args = ["flash"]
        if repartition {
            guard let p = pit ?? detectedPit else {
                r.append("⚠ 리파티션에는 PIT 파일이 필요합니다.\n")
                return
            }
            args += ["--repartition", "--pit", p.path]
        }
        for e in sel {
            args += ["--" + e.partition.trimmingCharacters(in: .whitespaces), e.file.path]
        }
        if !autoReboot { args.append("--no-reboot") }
        if resume { args.append("--resume") }

        let res = await r.run("heimdall", args)
        if res.code == 0 {
            r.append("\n✅ 플래시 완료\n")
            resume = !autoReboot
        } else {
            r.append("\n❌ 플래시 실패 (종료 코드 \(res.code)). 케이블/포트를 바꾸거나 기기를 다시 Download 모드로 진입한 뒤 재시도하세요.\n")
        }
    }
}
