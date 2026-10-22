import Cocoa
import ApplicationServices

// MARK: - 异步日志（鼠标回调里绝不碰磁盘）

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/FinderOpenInIterm.log")

let logQueue = DispatchQueue(label: "log", qos: .utility)

let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss.SSS"
    return f
}()

func log(_ message: String) {
    let line = "[\(logFormatter.string(from: Date()))] \(message)\n"
    logQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - Accessibility 辅助

/// 单次 AX 调用的超时，防止 Finder 卡住时把我们拖死
let axTimeout: Float = 0.2

func copyAttr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func asElement(_ value: CFTypeRef) -> AXUIElement {
    unsafeBitCast(value, to: AXUIElement.self)
}

func elementFrame(_ element: AXUIElement) -> CGRect? {
    guard let pv = copyAttr(element, kAXPositionAttribute),
          let sv = copyAttr(element, kAXSizeAttribute),
          CFGetTypeID(pv) == AXValueGetTypeID(),
          CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }

    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(pv, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeBitCast(sv, to: AXValue.self), .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

func elementURL(_ element: AXUIElement) -> URL? {
    guard let value = copyAttr(element, kAXURLAttribute),
          CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
    return (unsafeBitCast(value, to: CFURL.self) as URL)
}

func elementRole(_ element: AXUIElement) -> String? {
    return copyAttr(element, kAXRoleAttribute) as? String
}

func elementChildren(_ element: AXUIElement) -> [AXUIElement] {
    guard let value = copyAttr(element, kAXChildrenAttribute),
          let array = value as? [AnyObject] else { return [] }
    return array.map { unsafeBitCast($0, to: AXUIElement.self) }
}

/// Finder 返回的是 file:///.file/id=... 这种引用式 URL，先转成路径式再判断
func folderURL(from url: URL) -> URL? {
    guard url.isFileURL, let pathURL = (url as NSURL).filePathURL else { return nil }
    guard (try? pathURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
    return pathURL
}

/// 只在“恰好代表一个项目”的容器里取 URL；查出多个说明是整片图标区，放弃
func uniqueURL(in element: AXUIElement, depth: Int = 0, maxDepth: Int = 3, found: inout [URL]) {
    guard found.count < 2 else { return }
    if let url = elementURL(element) {
        found.append(url)
        return
    }
    guard depth < maxDepth else { return }
    for child in elementChildren(element) {
        uniqueURL(in: child, depth: depth + 1, maxDepth: maxDepth, found: &found)
        if found.count >= 2 { return }
    }
}

private var fallbackBest: (url: URL, area: CGFloat)?
private var fallbackVisited = 0
private var fallbackDeadline = Date()

/// 图标视图里文件夹名不在 AX 树的可命中范围内，按“图标下方 56pt 属于标签区”兜底。
/// 全程有时间和节点数上限，只在这个后台队列上跑，不会阻塞输入。
func geometricFallback(in element: AXUIElement, point: CGPoint, probe: CGRect, depth: Int) {
    guard depth < 16, fallbackVisited < 600, Date() < fallbackDeadline else { return }
    fallbackVisited += 1

    if let url = elementURL(element) {
        guard let frame = elementFrame(element) else { return }
        let hitRect = CGRect(x: frame.minX - 12, y: frame.minY,
                             width: frame.width + 24, height: frame.height + 56)
        guard hitRect.contains(point), let folder = folderURL(from: url) else { return }
        let area = frame.width * frame.height
        if fallbackBest == nil || area < fallbackBest!.area {
            fallbackBest = (folder, area)
        }
        return
    }

    for child in elementChildren(element) {
        guard let frame = elementFrame(child), frame.intersects(probe) else { continue }
        geometricFallback(in: child, point: point, probe: probe, depth: depth + 1)
    }
}

func folderURL(at point: CGPoint) -> URL? {
    var hitReference: AXUIElement?
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, axTimeout)
    let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hitReference)
    guard error == .success, let hit = hitReference else {
        log("hit-test failed: \(error.rawValue)")
        return nil
    }

    // 沿命中元素往上走，碰到列表/滚动区/窗口就停，避免把整片图标区当成一个项目
    var node: AXUIElement? = hit
    var steps = 0
    while let current = node, steps < 12 {
        let role = elementRole(current) ?? ""
        if role == kAXWindowRole || role == kAXScrollAreaRole || role == kAXListRole
            || role == kAXBrowserRole || role == kAXApplicationRole {
            break
        }
        var found: [URL] = []
        uniqueURL(in: current, found: &found)
        if found.count == 1, let folder = folderURL(from: found[0]) {
            return folder
        }
        if let parent = copyAttr(current, kAXParentAttribute) {
            node = asElement(parent)
        } else {
            node = nil
        }
        steps += 1
    }

    // 兜底：图标视图里点文件夹名，命中的是没有子元素的空白容器
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
        return nil
    }
    let app = AXUIElementCreateApplication(finder.processIdentifier)
    AXUIElementSetMessagingTimeout(app, axTimeout)

    fallbackBest = nil
    fallbackVisited = 0
    fallbackDeadline = Date().addingTimeInterval(0.2)
    let probe = CGRect(x: point.x - 140, y: point.y - 30, width: 280, height: 180)
    geometricFallback(in: app, point: point, probe: probe, depth: 0)
    return fallbackBest?.url
}

// MARK: - iTerm2

func shellQuoted(_ path: String) -> String {
    return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func appleScriptLiteral(_ text: String) -> String {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

/// 必须在后台队列调用：NSAppleScript 是同步阻塞的，可能等用户点授权弹窗
func openInIterm(_ path: String) {
    let command = "cd -- " + shellQuoted(path)
    let source = """
    tell application "iTerm2"
        activate
        set newWindow to (create window with default profile)
        tell current session of newWindow
            write text \(appleScriptLiteral(command))
        end tell
    end tell
    """
    guard let script = NSAppleScript(source: source) else {
        log("failed to build AppleScript")
        return
    }
    var errorInfo: NSDictionary?
    script.executeAndReturnError(&errorInfo)
    if let errorInfo = errorInfo {
        log("AppleScript error: \(errorInfo)")
    } else {
        log("opened iTerm2 at \(path)")
    }
}

// MARK: - 后台处理

let workQueue = DispatchQueue(label: "work", qos: .userInitiated)

func resolveAndOpen(at point: CGPoint) {
    let started = Date()
    let folder = folderURL(at: point)
    let elapsed = Date().timeIntervalSince(started) * 1000
    guard let folder = folder else {
        log(String(format: "no folder at %.0f,%.0f (%.0fms)", point.x, point.y, elapsed))
        return
    }
    log(String(format: "resolved %@ in %.0fms", folder.path, elapsed))
    openInIterm(folder.path)
}

// MARK: - 事件拦截

var eventTap: CFMachPort?
var swallowNextMouseUp = false

/// 由 NSWorkspace 通知在主线程更新，回调里只读 Bool，避免任何 XPC
var finderIsFrontmost = false
var timeoutTimestamps: [Date] = []

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        timeoutTimestamps.append(Date())
        timeoutTimestamps.removeAll { $0.timeIntervalSinceNow < -60 }

        // 兜底保险：反复超时就彻底停用，宁可功能失效也不能再拖住系统输入
        if timeoutTimestamps.count >= 3 {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
            log("FATAL: event tap 60 秒内超时 \(timeoutTimestamps.count) 次，已自动停用")
            return Unmanaged.passUnretained(event)
        }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        log("event tap re-enabled after timeout")
        return Unmanaged.passUnretained(event)
    }

    if type == .leftMouseUp {
        if swallowNextMouseUp {
            swallowNextMouseUp = false
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .leftMouseDown else {
        return Unmanaged.passUnretained(event)
    }

    // 这里只做微秒级的判断，任何 AX / 磁盘 / AppleScript 都必须扔到后台
    guard event.flags.contains(.maskCommand),
          event.flags.contains(.maskAlternate),
          event.getIntegerValueField(.mouseEventClickState) == 2,
          finderIsFrontmost else {
        return Unmanaged.passUnretained(event)
    }

    let startedAt = DispatchTime.now().uptimeNanoseconds
    let point = event.location
    workQueue.async { resolveAndOpen(at: point) }
    let cost = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
    if cost > 5 {
        log(String(format: "callback took %.1fms", cost))
    }
    return nil
}

func startEventTap() {
    let thread = Thread {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: tapCallback,
                                          userInfo: nil) else {
            log("failed to create event tap (accessibility not granted?)")
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("event tap installed")
        CFRunLoopRun()
    }
    thread.name = "event-tap"
    thread.start()
}

// MARK: - 启动

let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "--open" {
    openInIterm(arguments[2])
    exit(0)
}

NSApplication.shared.setActivationPolicy(.accessory)

finderIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil,
    queue: .main
) { note in
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    finderIsFrontmost = app?.bundleIdentifier == "com.apple.finder"
}

let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
)
log("launch: accessibility trusted = \(trusted)")

if trusted {
    startEventTap()
} else {
    log("waiting for accessibility permission")
    Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { timer in
        if AXIsProcessTrusted() {
            timer.invalidate()
            startEventTap()
        }
    }
}

NSApplication.shared.run()
