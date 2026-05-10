#!/usr/bin/env swift
import Foundation

#if os(macOS)
import AppKit
import CoreGraphics

struct Config {
    static let closeApps = ["Discord"]
    static let quitGraceSeconds = 4
    static let chillWidth = 1280
    static let chillHeight = 800
    static let chillRefreshHz = 60
}

struct DisplayModeState: Codable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
}

struct LockState: Codable {
    let displayID: UInt32
    let previousMode: DisplayModeState
    let previousLowPowerMode: Int
    let createdAt: Date
}

enum VNChillError: Error, CustomStringConvertible {
    case missingBuiltInDisplay
    case currentModeUnavailable
    case chillModeUnavailable
    case restoreModeUnavailable
    case displayConfigBeginFailed(CGError)
    case displayConfigSetFailed(CGError)
    case displayConfigCommitFailed(CGError)
    case pmsetReadFailed
    case pmsetSetFailed(Int32, String)

    var description: String {
        switch self {
        case .missingBuiltInDisplay:
            return "No built-in display was detected."
        case .currentModeUnavailable:
            return "Unable to read current display mode."
        case .chillModeUnavailable:
            return "Could not find a compatible chill mode."
        case .restoreModeUnavailable:
            return "Could not find the previous display mode to restore."
        case let .displayConfigBeginFailed(error):
            return "Failed to begin display configuration: \(error)."
        case let .displayConfigSetFailed(error):
            return "Failed to set display mode: \(error)."
        case let .displayConfigCommitFailed(error):
            return "Failed to persist display configuration: \(error)."
        case .pmsetReadFailed:
            return "Failed to read current Low Power Mode from pmset."
        case let .pmsetSetFailed(code, message):
            return "Failed to set Low Power Mode (exit \(code)): \(message)"
        }
    }
}

func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: Date())
}

func log(_ message: String) {
    print("[\(timestamp())] \(message)")
}

func lockFileURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vn-chill.json")
}

func runProcess(_ launchPath: String, _ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (1, "", error.localizedDescription)
    }

    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let out = String(data: outData, encoding: .utf8) ?? ""
    let err = String(data: errData, encoding: .utf8) ?? ""
    return (process.terminationStatus, out, err)
}

func getOnlineDisplays() -> [CGDirectDisplayID] {
    var activeCount: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &activeCount)
    guard activeCount > 0 else { return [] }

    var displays = [CGDirectDisplayID](repeating: 0, count: Int(activeCount))
    CGGetOnlineDisplayList(activeCount, &displays, &activeCount)
    return displays
}

func builtInDisplayID() -> CGDirectDisplayID? {
    getOnlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }
}

func currentModeState(for displayID: CGDirectDisplayID) -> DisplayModeState? {
    guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
    return DisplayModeState(
        width: mode.width,
        height: mode.height,
        pixelWidth: mode.pixelWidth,
        pixelHeight: mode.pixelHeight,
        refreshRate: mode.refreshRate
    )
}

func allModes(for displayID: CGDirectDisplayID) -> [CGDisplayMode] {
    (CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode]) ?? []
}

func restoreMode(for displayID: CGDirectDisplayID, from state: DisplayModeState) -> CGDisplayMode? {
    allModes(for: displayID).first {
        $0.width == state.width &&
            $0.height == state.height &&
            $0.pixelWidth == state.pixelWidth &&
            $0.pixelHeight == state.pixelHeight &&
            abs($0.refreshRate - state.refreshRate) < 0.1
    }
}

func chillMode(for displayID: CGDirectDisplayID) -> CGDisplayMode? {
    let candidates = allModes(for: displayID).filter {
        $0.width == Config.chillWidth && $0.height == Config.chillHeight
    }
    guard !candidates.isEmpty else { return nil }

    return candidates.min {
        abs($0.refreshRate - Double(Config.chillRefreshHz)) < abs($1.refreshRate - Double(Config.chillRefreshHz))
    }
}

func setDisplayMode(_ mode: CGDisplayMode, for displayID: CGDirectDisplayID) throws {
    var configRef: CGDisplayConfigRef?
    let beginResult = CGBeginDisplayConfiguration(&configRef)
    guard beginResult == .success else {
        throw VNChillError.displayConfigBeginFailed(beginResult)
    }

    guard let configRef else {
        throw VNChillError.displayConfigBeginFailed(.failure)
    }

    let setResult = CGConfigureDisplayWithDisplayMode(configRef, displayID, mode, nil)
    guard setResult == .success else {
        throw VNChillError.displayConfigSetFailed(setResult)
    }

    let commitResult = CGCompleteDisplayConfiguration(configRef, .permanently)
    guard commitResult == .success else {
        throw VNChillError.displayConfigCommitFailed(commitResult)
    }
}

func getLowPowerModeState() throws -> Int {
    let result = runProcess("/usr/bin/pmset", ["-g"])
    guard result.status == 0 else { throw VNChillError.pmsetReadFailed }

    guard let lowPowerLine = result.stdout
        .split(separator: "\n")
        .map({ $0.trimmingCharacters(in: .whitespaces) })
        .first(where: { $0.hasPrefix("lowpowermode") })
    else {
        throw VNChillError.pmsetReadFailed
    }

    let fields = lowPowerLine.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 2, let value = Int(fields[1]) else {
        throw VNChillError.pmsetReadFailed
    }
    return value
}

func setLowPowerMode(_ value: Int) throws {
    let result = runProcess("/usr/bin/sudo", ["/usr/bin/pmset", "-a", "lowpowermode", String(value)])
    guard result.status == 0 else {
        let combined = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        throw VNChillError.pmsetSetFailed(result.status, combined)
    }
}

func runningApps(named name: String) -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { $0.localizedName == name }
}

func quitConfiguredApps() {
    for name in Config.closeApps {
        let apps = runningApps(named: name)
        if apps.isEmpty {
            log("Not running (skip): \(name)")
            continue
        }

        log("Requesting quit: \(name)")
        apps.forEach { _ = $0.terminate() }

        var waited = 0
        while waited < Config.quitGraceSeconds {
            if runningApps(named: name).isEmpty { break }
            Thread.sleep(forTimeInterval: 1)
            waited += 1
        }

        let remaining = runningApps(named: name)
        if remaining.isEmpty {
            log("Exited cleanly: \(name)")
        } else {
            log("Force killing: \(name)")
            remaining.forEach { _ = $0.forceTerminate() }
        }
    }
}

func writeLockFile(_ state: LockState) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(state)
    try data.write(to: lockFileURL(), options: .atomic)
}

func readLockFile() throws -> LockState {
    let data = try Data(contentsOf: lockFileURL())
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(LockState.self, from: data)
}

func enterChillMode() throws {
    guard let displayID = builtInDisplayID() else {
        throw VNChillError.missingBuiltInDisplay
    }
    guard let previousMode = currentModeState(for: displayID) else {
        throw VNChillError.currentModeUnavailable
    }
    guard let targetMode = chillMode(for: displayID) else {
        throw VNChillError.chillModeUnavailable
    }

    let previousLPM = try getLowPowerModeState()

    log("Entering VN Chill Mode")
    quitConfiguredApps()
    log("Current display mode: \(previousMode.width)x\(previousMode.height) @ \(Int(previousMode.refreshRate.rounded()))Hz")
    log("Current Low Power Mode: \(previousLPM)")

    try setLowPowerMode(1)
    try setDisplayMode(targetMode, for: displayID)

    try writeLockFile(
        LockState(
            displayID: displayID,
            previousMode: previousMode,
            previousLowPowerMode: previousLPM,
            createdAt: Date()
        )
    )

    log("Chill mode enabled. Lockfile: \(lockFileURL().path)")
}

func exitChillMode() throws {
    let state = try readLockFile()
    let displayID = getOnlineDisplays().contains(state.displayID) ? state.displayID : (builtInDisplayID() ?? state.displayID)
    guard let mode = restoreMode(for: displayID, from: state.previousMode) else {
        throw VNChillError.restoreModeUnavailable
    }

    log("Exiting VN Chill Mode (restoring prior settings)")
    try setDisplayMode(mode, for: displayID)
    try setLowPowerMode(state.previousLowPowerMode)

    try? FileManager.default.removeItem(at: lockFileURL())
    log("Restored. Lockfile removed.")
}

do {
    if FileManager.default.fileExists(atPath: lockFileURL().path) {
        try exitChillMode()
    } else {
        try enterChillMode()
    }
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
#else
fputs("Error: vn-chill.swift only supports macOS.\n", stderr)
exit(1)
#endif
