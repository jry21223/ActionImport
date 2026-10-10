import Foundation

/// Describes what the menu-bar panel should show for a given import state.
///
/// Pure data and logic with no AppKit dependency, so the check suite can
/// exercise every phase transition. The panel reads these strings and symbol
/// names; it does not decide them.
public struct ImportPresentation: Sendable, Equatable {
    public enum Phase: String, Sendable, CaseIterable {
        case waiting, scanning, ready, copying, checking, verifying, failed, completed
    }

    public enum Action: String, Sendable {
        case configure, start, retry, stop, open
    }

    public enum Symbol: String, Sendable {
        case arrowRight = "arrow.right"
        case arrowDown = "arrow.down"
        case arrowClockwise = "arrow.clockwise"
        case arrowUpRight = "arrow.up.right"
        case stop = "stop"
    }

    public struct State: Sendable, Equatable {
        public var phase: Phase
        public var configured: Bool
        public var busy: Bool
        public var scanning: Bool
        public var importActive: Bool
        public var cameraConnected: Bool
        public var scannedFiles: Int
        public var lastImported: Int

        public init(
            phase: Phase = .waiting,
            configured: Bool = false,
            busy: Bool = false,
            scanning: Bool = false,
            importActive: Bool = false,
            cameraConnected: Bool = false,
            scannedFiles: Int = 0,
            lastImported: Int = 0
        ) {
            self.phase = phase
            self.configured = configured
            self.busy = busy
            self.scanning = scanning
            self.importActive = importActive
            self.cameraConnected = cameraConnected
            self.scannedFiles = scannedFiles
            self.lastImported = lastImported
        }
    }

    public let headline: String
    public let primaryTitle: String
    public let primarySymbol: Symbol?
    public let primaryAction: Action
    public let primaryEnabled: Bool

    public init(_ state: State) {
        headline = Self.headline(for: state)
        let primary = Self.primary(for: state)
        primaryTitle = primary.title
        primarySymbol = primary.symbol
        primaryAction = primary.action
        primaryEnabled = primary.enabled
    }

    /// Caption for an in-flight import phase, shown while bytes are moving.
    public static func progressLabel(_ phase: ImportProgress.Phase) -> String {
        switch phase {
        case .copying: "复制"
        case .verifying: "校验"
        case .checking: "核对已有文件"
        case .completed: "已完成文件"
        }
    }

    private static func headline(for state: State) -> String {
        switch state.phase {
        case .scanning: "查找视频"
        case .copying: "正在复制"
        case .checking: "核对素材"
        case .verifying: "正在校验"
        case .failed: "需要处理"
        case .completed: state.importActive ? "正在导入" : (state.lastImported > 0 ? "已收好" : "没有新视频")
        case .ready: state.scannedFiles > 0 ? "准备导入" : "没有新视频"
        case .waiting: state.configured ? "等待相机" : "准备导入"
        }
    }

    private static func primary(for state: State) -> (title: String, symbol: Symbol?, action: Action, enabled: Bool) {
        if !state.configured { return ("完成设置", .arrowRight, .configure, true) }
        if state.busy { return ("停止导入", .stop, .stop, true) }
        if state.scanning { return ("查找视频…", nil, .start, false) }
        if state.phase == .failed { return ("重试导入", .arrowClockwise, .retry, state.cameraConnected) }
        if state.phase == .ready && state.scannedFiles > 0 { return ("开始导入", .arrowDown, .start, state.cameraConnected) }
        return ("打开目录", .arrowUpRight, .open, true)
    }
}
