#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Foundation

struct Config {
    let appPath: String
    let scenario: String
    let artifactsDir: String
    let launch: Bool
}

enum SmokeError: LocalizedError {
    case invalidArguments(String)
    case unsupportedScenario(String)
    case missingBundleIdentifier(String)
    case accessibilityNotTrusted
    case launchFailed(String)
    case appNotRunning(String)
    case windowUnavailable
    case elementNotFound(String)
    case pressFailed(String)
    case workspaceCountDidNotIncrease(Int, Int)
    case crashDetected(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message):
            return message
        case let .unsupportedScenario(name):
            return "Unsupported scenario: \(name)"
        case let .missingBundleIdentifier(path):
            return "Could not read CFBundleIdentifier from \(path)"
        case .accessibilityNotTrusted:
            return "Accessibility access is required. Grant it to the process running this script, then retry."
        case let .launchFailed(message):
            return "Failed to launch app: \(message)"
        case let .appNotRunning(bundleId):
            return "App is not running for bundle id \(bundleId)"
        case .windowUnavailable:
            return "Timed out waiting for the app window to appear"
        case let .elementNotFound(identifier):
            return "Could not find accessibility element \(identifier)"
        case let .pressFailed(identifier):
            return "Failed to press accessibility element \(identifier)"
        case let .workspaceCountDidNotIncrease(before, after):
            return "Workspace row count did not increase after clicking new workspace (\(before) -> \(after))"
        case let .crashDetected(path):
            return "Detected new crash report: \(path)"
        }
    }
}

struct PressAttemptDetails {
    let actionResult: AXError
    let fallbackAttempted: Bool
    let fallbackSucceeded: Bool
}

let exactButtonIdentifiers: [String: String] = [
    "toggleSidebar": "titlebarControl.toggleSidebar",
    "newWorkspace": "titlebarControl.newTab",
]
let sidebarWorkspaceRowPrefix = "SidebarWorkspaceRow."

func parseArgs() throws -> Config {
    var appPath: String?
    var scenario: String?
    var artifactsDir: String?
    var launch = false

    var index = 1
    while index < CommandLine.arguments.count {
        let argument = CommandLine.arguments[index]
        switch argument {
        case "--app-path":
            index += 1
            guard index < CommandLine.arguments.count else {
                throw SmokeError.invalidArguments("--app-path requires a value")
            }
            appPath = CommandLine.arguments[index]
        case "--scenario":
            index += 1
            guard index < CommandLine.arguments.count else {
                throw SmokeError.invalidArguments("--scenario requires a value")
            }
            scenario = CommandLine.arguments[index]
        case "--artifacts-dir":
            index += 1
            guard index < CommandLine.arguments.count else {
                throw SmokeError.invalidArguments("--artifacts-dir requires a value")
            }
            artifactsDir = CommandLine.arguments[index]
        case "--launch":
            launch = true
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            throw SmokeError.invalidArguments("Unknown argument: \(argument)")
        }
        index += 1
    }

    guard let appPath, !appPath.isEmpty else {
        throw SmokeError.invalidArguments("--app-path is required")
    }
    guard let scenario, !scenario.isEmpty else {
        throw SmokeError.invalidArguments("--scenario is required")
    }
    guard let artifactsDir, !artifactsDir.isEmpty else {
        throw SmokeError.invalidArguments("--artifacts-dir is required")
    }

    return Config(
        appPath: appPath,
        scenario: scenario,
        artifactsDir: artifactsDir,
        launch: launch
    )
}

func printUsage() {
    let usage = """
    Usage: mac-smoke.swift --app-path <path> --scenario <name> --artifacts-dir <path> [--launch]

    Scenarios:
      titlebar-new-workspace
    """
    print(usage)
}

func plistValue(_ key: String, in appPath: String) -> Any? {
    let infoURL = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: infoURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        return nil
    }
    return plist[key]
}

func bundleIdentifier(for appPath: String) throws -> String {
    guard let bundleId = plistValue("CFBundleIdentifier", in: appPath) as? String, !bundleId.isEmpty else {
        throw SmokeError.missingBundleIdentifier(appPath)
    }
    return bundleId
}

func crashReportURLs() -> [URL] {
    let reportsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports")
    guard let urls = try? FileManager.default.contentsOfDirectory(
        at: reportsDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    return urls
        .filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("cmux-") && (name.hasSuffix(".ips") || name.hasSuffix(".crash"))
        }
        .sorted { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
}

func waitFor(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.2,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }
    return condition()
}

func runProcess(_ launchPath: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
}

@discardableResult
func captureScreenshot(name: String, artifactsURL: URL) -> URL? {
    let targetURL = artifactsURL.appendingPathComponent(name)
    do {
        try runProcess("/usr/sbin/screencapture", ["-x", targetURL.path])
        return targetURL
    } catch {
        return nil
    }
}

func launchApplication(at appURL: URL) throws -> NSRunningApplication {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.createsNewApplicationInstance = false

    let semaphore = DispatchSemaphore(value: 0)
    var launchedApplication: NSRunningApplication?
    var launchError: Error?

    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
        launchedApplication = app
        launchError = error
        semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + 20) == .timedOut {
        throw SmokeError.launchFailed("Timed out waiting for LaunchServices")
    }
    if let launchError {
        throw SmokeError.launchFailed(launchError.localizedDescription)
    }
    guard let launchedApplication else {
        throw SmokeError.launchFailed("LaunchServices returned no running app")
    }
    return launchedApplication
}

func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .first(where: { !$0.isTerminated })
}

func axValue(_ element: AXUIElement, attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success else { return nil }
    return value
}

func axElements(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
    guard let value = axValue(element, attribute: attribute) else { return [] }
    if CFGetTypeID(value) == AXUIElementGetTypeID() {
        return [unsafeBitCast(value, to: AXUIElement.self)]
    }
    if let array = value as? [AXUIElement] {
        return array
    }
    return []
}

func axString(_ element: AXUIElement, attribute: CFString) -> String? {
    axValue(element, attribute: attribute) as? String
}

func axStrings(_ element: AXUIElement, attribute: CFString) -> [String] {
    guard let value = axValue(element, attribute: attribute) else { return [] }
    return value as? [String] ?? []
}

func axCGPoint(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
    guard let value = axValue(element, attribute: attribute) else { return nil }
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValueRef = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValueRef) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(axValueRef, .cgPoint, &point) else { return nil }
    return point
}

func axCGSize(_ element: AXUIElement, attribute: CFString) -> CGSize? {
    guard let value = axValue(element, attribute: attribute) else { return nil }
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValueRef = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValueRef) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(axValueRef, .cgSize, &size) else { return nil }
    return size
}

func axCGRect(_ element: AXUIElement, attribute: CFString) -> CGRect? {
    guard let value = axValue(element, attribute: attribute) else { return nil }
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValueRef = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValueRef) == .cgRect else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(axValueRef, .cgRect, &rect) else { return nil }
    return rect
}

func axIdentifier(_ element: AXUIElement) -> String? {
    axString(element, attribute: kAXIdentifierAttribute as CFString)
}

func axRole(_ element: AXUIElement) -> String? {
    axString(element, attribute: kAXRoleAttribute as CFString)
}

func axActionNames(_ element: AXUIElement) -> [String] {
    var actionNames: CFArray?
    let result = AXUIElementCopyActionNames(element, &actionNames)
    guard result == .success, let actionNames else { return [] }
    return actionNames as? [String] ?? []
}

func isPressableElement(_ element: AXUIElement) -> Bool {
    if axRole(element) == kAXButtonRole as String {
        return true
    }
    return axActionNames(element).contains(kAXPressAction as String)
}

func axPointerKey(_ element: AXUIElement) -> UnsafeMutableRawPointer {
    Unmanaged.passUnretained(element).toOpaque()
}

func descendantElements(
    of root: AXUIElement,
    maxDepth: Int = 16
) -> [AXUIElement] {
    var results: [AXUIElement] = []
    var visited = Set<UnsafeMutableRawPointer>()

    func traverse(_ element: AXUIElement, depth: Int) {
        let key = axPointerKey(element)
        guard visited.insert(key).inserted else { return }
        results.append(element)
        guard depth < maxDepth else { return }

        let childAttributes: [CFString] = [
            kAXChildrenAttribute as CFString,
            kAXVisibleChildrenAttribute as CFString,
            kAXRowsAttribute as CFString,
            kAXContentsAttribute as CFString,
        ]
        for attribute in childAttributes {
            for child in axElements(element, attribute: attribute) {
                traverse(child, depth: depth + 1)
            }
        }
    }

    traverse(root, depth: 0)
    return results
}

func firstElement(
    in root: AXUIElement,
    matching predicate: (AXUIElement) -> Bool
) -> AXUIElement? {
    descendantElements(of: root).first(where: predicate)
}

func matchingElements(
    in root: AXUIElement,
    matching predicate: (AXUIElement) -> Bool
) -> [AXUIElement] {
    descendantElements(of: root).filter(predicate)
}

func waitForWindow(appElement: AXUIElement, timeout: TimeInterval) -> Bool {
    waitFor(timeout: timeout) {
        !axElements(appElement, attribute: kAXWindowsAttribute as CFString).isEmpty
    }
}

func findElement(byIdentifier identifier: String, in appElement: AXUIElement) -> AXUIElement? {
    let matches = matchingElements(in: appElement) { element in
        axIdentifier(element) == identifier
    }
    return matches.first(where: isPressableElement) ?? matches.first
}

func countSidebarWorkspaceRows(in appElement: AXUIElement) -> Int {
    matchingElements(in: appElement) { element in
        guard let identifier = axIdentifier(element) else { return false }
        return identifier.hasPrefix(sidebarWorkspaceRowPrefix)
    }.count
}

func clickElementCenter(_ element: AXUIElement) -> Bool {
    let center: CGPoint
    if let frame = axCGRect(element, attribute: "AXFrame" as CFString) {
        center = CGPoint(x: frame.midX, y: frame.midY)
    } else if let position = axCGPoint(element, attribute: kAXPositionAttribute as CFString),
              let size = axCGSize(element, attribute: kAXSizeAttribute as CFString) {
        center = CGPoint(x: position.x + (size.width / 2), y: position.y + (size.height / 2))
    } else {
        return false
    }
    guard let source = CGEventSource(stateID: .hidSystemState),
          let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left),
          let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
          let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left) else {
        return false
    }

    move.post(tap: .cghidEventTap)
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
}

func press(_ element: AXUIElement) -> PressAttemptDetails {
    let actionResult = AXUIElementPerformAction(element, kAXPressAction as CFString)
    if actionResult == .success {
        return PressAttemptDetails(
            actionResult: actionResult,
            fallbackAttempted: false,
            fallbackSucceeded: false
        )
    }

    let fallbackSucceeded = clickElementCenter(element)
    return PressAttemptDetails(
        actionResult: actionResult,
        fallbackAttempted: true,
        fallbackSucceeded: fallbackSucceeded
    )
}

func copyCrashReport(_ reportURL: URL, to artifactsURL: URL) throws -> URL {
    let destinationURL = artifactsURL.appendingPathComponent(reportURL.lastPathComponent)
    if FileManager.default.fileExists(atPath: destinationURL.path) {
        try FileManager.default.removeItem(at: destinationURL)
    }
    try FileManager.default.copyItem(at: reportURL, to: destinationURL)
    return destinationURL
}

func writeJSON(_ object: [String: Any], to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
        return
    }
    try? data.write(to: url, options: .atomic)
}

let config: Config
do {
    config = try parseArgs()
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    printUsage()
    exit(2)
}

let artifactsURL = URL(fileURLWithPath: config.artifactsDir, isDirectory: true)
try? FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)

var summary: [String: Any] = [
    "appPath": config.appPath,
    "scenario": config.scenario,
    "artifactsDir": config.artifactsDir,
    "launch": config.launch,
]

let summaryURL = artifactsURL.appendingPathComponent("summary.json")
let baselineCrashReports = crashReportURLs()
let baselineCrashNames = Set(baselineCrashReports.map(\.lastPathComponent))

do {
    guard config.scenario == "titlebar-new-workspace" else {
        throw SmokeError.unsupportedScenario(config.scenario)
    }

    let bundleId = try bundleIdentifier(for: config.appPath)
    summary["bundleId"] = bundleId

    guard AXIsProcessTrusted() else {
        throw SmokeError.accessibilityNotTrusted
    }

    let runningApp: NSRunningApplication
    if config.launch {
        runningApp = try launchApplication(at: URL(fileURLWithPath: config.appPath))
    } else if let existing = runningApplication(bundleIdentifier: bundleId) {
        runningApp = existing
    } else {
        throw SmokeError.appNotRunning(bundleId)
    }

    summary["pid"] = runningApp.processIdentifier
    _ = runningApp.activate(options: [.activateAllWindows])

    let appElement = AXUIElementCreateApplication(runningApp.processIdentifier)
    guard waitForWindow(appElement: appElement, timeout: 15) else {
        throw SmokeError.windowUnavailable
    }

    var baselineRowCount = countSidebarWorkspaceRows(in: appElement)
    if baselineRowCount == 0,
       let toggleButton = findElement(byIdentifier: exactButtonIdentifiers["toggleSidebar"]!, in: appElement) {
        let togglePress = press(toggleButton)
        if togglePress.actionResult == .success || togglePress.fallbackSucceeded {
        _ = waitFor(timeout: 3) {
            countSidebarWorkspaceRows(in: appElement) > 0
        }
        baselineRowCount = countSidebarWorkspaceRows(in: appElement)
        summary["sidebarToggledForVisibility"] = true
        } else {
            summary["sidebarToggledForVisibility"] = false
        }
    } else {
        summary["sidebarToggledForVisibility"] = false
    }
    summary["workspaceRowsBefore"] = baselineRowCount

    let beforeScreenshot = captureScreenshot(name: "before.png", artifactsURL: artifactsURL)
    summary["beforeScreenshot"] = beforeScreenshot?.path ?? ""

    guard let newWorkspaceButton = findElement(byIdentifier: exactButtonIdentifiers["newWorkspace"]!, in: appElement) else {
        throw SmokeError.elementNotFound(exactButtonIdentifiers["newWorkspace"]!)
    }
    summary["newWorkspaceRole"] = axRole(newWorkspaceButton) ?? ""
    summary["newWorkspaceActions"] = axActionNames(newWorkspaceButton)
    summary["newWorkspacePosition"] = axCGPoint(newWorkspaceButton, attribute: kAXPositionAttribute as CFString).map(NSStringFromPoint) ?? ""
    summary["newWorkspaceSize"] = axCGSize(newWorkspaceButton, attribute: kAXSizeAttribute as CFString).map(NSStringFromSize) ?? ""
    summary["newWorkspaceFrame"] = axCGRect(newWorkspaceButton, attribute: "AXFrame" as CFString).map(NSStringFromRect) ?? ""

    let pressDetails = press(newWorkspaceButton)
    summary["newWorkspacePressAXError"] = pressDetails.actionResult.rawValue
    summary["newWorkspacePressFallbackAttempted"] = pressDetails.fallbackAttempted
    summary["newWorkspacePressFallbackSucceeded"] = pressDetails.fallbackSucceeded
    guard pressDetails.actionResult == .success || pressDetails.fallbackSucceeded else {
        throw SmokeError.pressFailed(exactButtonIdentifiers["newWorkspace"]!)
    }

    let workspaceIncreaseObserved: Bool
    if baselineRowCount > 0 {
        workspaceIncreaseObserved = waitFor(timeout: 5) {
            countSidebarWorkspaceRows(in: appElement) > baselineRowCount
        }
        let afterCount = countSidebarWorkspaceRows(in: appElement)
        summary["workspaceRowsAfter"] = afterCount
        summary["workspaceIncreaseObserved"] = workspaceIncreaseObserved
        if !workspaceIncreaseObserved {
            throw SmokeError.workspaceCountDidNotIncrease(baselineRowCount, afterCount)
        }
    } else {
        workspaceIncreaseObserved = false
        summary["workspaceRowsAfter"] = 0
        summary["workspaceIncreaseObserved"] = false
        summary["workspaceIncreaseAssertion"] = "unavailable"
        _ = waitFor(timeout: 2) {
            !runningApp.isTerminated
        }
    }

    if runningApp.isTerminated {
        let newCrashReport = crashReportURLs().first { !baselineCrashNames.contains($0.lastPathComponent) }
        if let newCrashReport {
            let copiedReport = try copyCrashReport(newCrashReport, to: artifactsURL)
            summary["crashReport"] = copiedReport.path
            throw SmokeError.crashDetected(copiedReport.path)
        }
        throw SmokeError.launchFailed("App terminated during smoke scenario")
    }

    let newCrashReport = crashReportURLs().first { !baselineCrashNames.contains($0.lastPathComponent) }
    if let newCrashReport {
        let copiedReport = try copyCrashReport(newCrashReport, to: artifactsURL)
        summary["crashReport"] = copiedReport.path
        throw SmokeError.crashDetected(copiedReport.path)
    }

    let afterScreenshot = captureScreenshot(name: "after.png", artifactsURL: artifactsURL)
    summary["afterScreenshot"] = afterScreenshot?.path ?? ""
    summary["status"] = "passed"
    writeJSON(summary, to: summaryURL)
    print("Smoke scenario passed")
    print("Artifacts: \(artifactsURL.path)")
} catch {
    summary["status"] = "failed"
    summary["error"] = error.localizedDescription
    let failureScreenshot = captureScreenshot(name: "failure.png", artifactsURL: artifactsURL)
    summary["failureScreenshot"] = failureScreenshot?.path ?? ""
    writeJSON(summary, to: summaryURL)
    fputs("\(error.localizedDescription)\n", stderr)
    fputs("Artifacts: \(artifactsURL.path)\n", stderr)
    exit(1)
}
