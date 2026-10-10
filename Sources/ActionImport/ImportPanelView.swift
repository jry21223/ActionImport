@preconcurrency import AppKit

@MainActor
private enum PanelStyle {
    static let ink = NSColor(srgbRed: 0.137, green: 0.141, blue: 0.137, alpha: 1)
    static let paper = NSColor(srgbRed: 0.973, green: 0.957, blue: 0.918, alpha: 1)
    static let muted = NSColor(srgbRed: 0.737, green: 0.757, blue: 0.694, alpha: 1)
    static let line = NSColor(srgbRed: 0.251, green: 0.255, blue: 0.235, alpha: 1)
    static let orange = NSColor(srgbRed: 1, green: 0.408, blue: 0.114, alpha: 1)

    static func label(_ text: String, size: CGFloat = 14, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = paper
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    static func symbol(_ name: String, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
    }
}

@MainActor
final class PanelButton: NSButton {
    let primary: Bool
    var symbolName: String? { didSet { needsDisplay = true } }

    init(_ title: String, primary: Bool = false, symbol: String? = nil) {
        self.primary = primary
        self.symbolName = symbol
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError("Programmatic view") }

    override func draw(_ dirtyRect: NSRect) {
        let opacity: CGFloat = isEnabled ? 1 : 0.45
        let foreground = (primary ? PanelStyle.ink : PanelStyle.paper).withAlphaComponent(opacity)
        if primary {
            PanelStyle.paper.withAlphaComponent(isHighlighted ? 0.85 : opacity).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        } else if isHighlighted {
            PanelStyle.line.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = primary ? .left : .center
        let font = NSFont.systemFont(ofSize: primary ? 16 : 13, weight: primary ? .semibold : .regular)
        let textRect = NSRect(x: primary ? 16 : 0, y: (bounds.height - 20) / 2, width: bounds.width - (primary ? 54 : 0), height: 21)
        (title as NSString).draw(in: textRect, withAttributes: [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraph])
        if let symbolName, let image = PanelStyle.symbol(symbolName, color: foreground) {
            let x = primary ? bounds.width - 33 : (bounds.width - 18) / 2
            image.draw(in: NSRect(x: x, y: (bounds.height - 18) / 2, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: opacity, respectFlipped: true, hints: nil)
        }
        if window?.firstResponder === self {
            PanelStyle.orange.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

@MainActor
final class PanelSwitch: NSButton {
    init(_ accessibleTitle: String) {
        super.init(frame: .zero)
        title = accessibleTitle
        setButtonType(.switch)
        isBordered = false
        setAccessibilityLabel(accessibleTitle)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic view") }

    override func draw(_ dirtyRect: NSRect) {
        let opacity: CGFloat = isEnabled ? 1 : 0.4
        (state == .on ? PanelStyle.orange : NSColor(calibratedWhite: 0.34, alpha: 1)).withAlphaComponent(opacity).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 36, height: 22), xRadius: 11, yRadius: 11).fill()
        PanelStyle.paper.withAlphaComponent(opacity).setFill()
        NSBezierPath(ovalIn: NSRect(x: state == .on ? 17 : 3, y: 3, width: 16, height: 16)).fill()
        if window?.firstResponder === self {
            PanelStyle.paper.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 11, yRadius: 11)
            ring.lineWidth = 1
            ring.stroke()
        }
    }
}

@MainActor
final class ImportProgressLine: NSView {
    var doubleValue = 0.0 {
        didSet {
            setAccessibilityValue(doubleValue)
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("导入进度")
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(1)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic view") }

    override func draw(_ dirtyRect: NSRect) {
        PanelStyle.line.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5).fill()
        PanelStyle.orange.setFill()
        let width = bounds.width * min(1, max(0, doubleValue))
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

@MainActor
private final class PanelPage: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ImportPanelView: NSView {
    let cameraPicker = NSPopUpButton()
    let destinationLabel = PanelStyle.label("请选择保存目录", size: 13)
    let summaryLabel = PanelStyle.label("", size: 12)
    let stateLabel = PanelStyle.label("等待相机接入", size: 13)
    let fileLabel = PanelStyle.label("", size: 11)
    let progressBar = ImportProgressLine(frame: NSRect(x: 24, y: 192, width: 352, height: 3))
    let autoButton = PanelSwitch("相机接入后自动导入新增素材")
    let mainAutoButton = PanelSwitch("自动导入")
    let proxyButton = PanelSwitch("同时导入 LRF 代理文件")
    let loginButton = PanelSwitch("登录 Mac 时启动")
    let primaryButton = PanelButton("打开目录", primary: true, symbol: "arrow.up.right")
    let destinationButton = PanelButton("更改")
    let mainDestinationButton = PanelButton("")
    let refreshButton = PanelButton("刷新")
    let settingsButton = PanelButton("", symbol: "gearshape")
    let backButton = PanelButton("", symbol: "chevron.left")
    let quitButton = PanelButton("退出 ActionImport")
    let settingsFeedback = PanelStyle.label("", size: 11)
    private let mainPage = PanelPage()
    private let settingsPage = PanelPage()
    private let headline = PanelStyle.label("等待相机", size: 40, weight: .bold)
    private let deviceName = PanelStyle.label("选择相机", size: 15)
    private let connection = PanelStyle.label("未连接", size: 12)
    private let destination = PanelStyle.label("请选择保存目录", size: 16, weight: .semibold)
    private let dot = PanelStyle.label("●", size: 9)
    private(set) var showingSettings = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 434))
        wantsLayer = true
        layer?.backgroundColor = PanelStyle.ink.cgColor
        appearance = NSAppearance(named: .darkAqua)
        mainPage.frame = bounds
        settingsPage.frame = bounds
        addSubview(mainPage)
        addSubview(settingsPage)
        setupMain()
        setupSettings()
        showSettings(false)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic view") }

    func showSettings(_ show: Bool) {
        showingSettings = show
        mainPage.isHidden = show
        settingsPage.isHidden = !show
        window?.makeFirstResponder(show ? backButton : settingsButton)
    }

    func present(title: String, cameraName: String?, connected: Bool, destinationPath: String?, busy: Bool, scanning: Bool) {
        headline.stringValue = title
        deviceName.stringValue = cameraName ?? "选择相机"
        connection.stringValue = connected ? "已连接" : "未连接"
        dot.textColor = connected ? PanelStyle.orange : PanelStyle.muted
        destination.stringValue = destinationPath.map(Self.displayPath) ?? "请选择保存目录"
        destination.toolTip = destinationPath
        destinationLabel.stringValue = destinationPath.map(Self.displayPath) ?? "请选择保存目录"
        destinationLabel.toolTip = destinationPath
        progressBar.isHidden = !busy && !scanning
        stateLabel.toolTip = stateLabel.stringValue
        stateLabel.setAccessibilityHelp(stateLabel.stringValue)
        fileLabel.toolTip = fileLabel.stringValue
        mainAutoButton.state = autoButton.state
        mainAutoButton.isEnabled = autoButton.isEnabled
        for control in [autoButton, mainAutoButton, proxyButton, loginButton, primaryButton] { control.needsDisplay = true }
    }

    private static func displayPath(_ path: String) -> String {
        let movies = NSHomeDirectory() + "/Movies/"
        if path.hasPrefix(movies) { return "影片 / " + path.dropFirst(movies.count) }
        return path.replacingOccurrences(of: NSHomeDirectory() + "/", with: "~/", options: .anchored)
    }

    private func setupMain() {
        let logo = NSImageView(frame: NSRect(x: 24, y: 14, width: 28, height: 28))
        logo.image = NSImage(named: "AppLogo") ?? Self.menuIcon()
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.wantsLayer = true
        logo.layer?.cornerRadius = 7
        logo.layer?.masksToBounds = true
        mainPage.addSubview(logo)
        place(PanelStyle.label("ActionImport", size: 17, weight: .semibold), in: mainPage, x: 63, y: 18, width: 245, height: 23)
        place(settingsButton, in: mainPage, x: 345, y: 12, width: 32, height: 32)
        settingsButton.setAccessibilityLabel("设置")
        separator(in: mainPage, y: 55, fullWidth: true)
        place(headline, in: mainPage, x: 24, y: 76, width: 352, height: 50)
        place(stateLabel, in: mainPage, x: 24, y: 133, width: 352, height: 34)
        stateLabel.textColor = PanelStyle.muted
        place(fileLabel, in: mainPage, x: 24, y: 170, width: 352, height: 15)
        fileLabel.maximumNumberOfLines = 1
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.textColor = PanelStyle.muted
        mainPage.addSubview(progressBar)
        place(deviceName, in: mainPage, x: 24, y: 211, width: 253, height: 22)
        place(dot, in: mainPage, x: 298, y: 216, width: 12, height: 14)
        place(connection, in: mainPage, x: 312, y: 214, width: 64, height: 18)
        connection.textColor = PanelStyle.muted
        separator(in: mainPage, y: 245)
        place(mainDestinationButton, in: mainPage, x: 24, y: 253, width: 352, height: 60)
        mainDestinationButton.setAccessibilityLabel("更改保存目录")
        let folder = NSImageView(frame: NSRect(x: 24, y: 282, width: 21, height: 18))
        folder.image = PanelStyle.symbol("folder", color: PanelStyle.muted)
        mainPage.addSubview(folder)
        let locationCaption = PanelStyle.label("保存到", size: 12)
        locationCaption.textColor = PanelStyle.muted
        place(locationCaption, in: mainPage, x: 56, y: 257, width: 320, height: 17)
        place(destination, in: mainPage, x: 56, y: 280, width: 320, height: 33)
        destination.lineBreakMode = .byTruncatingMiddle
        mainPage.addSubview(mainDestinationButton, positioned: .above, relativeTo: nil)
        separator(in: mainPage, y: 321)
        place(primaryButton, in: mainPage, x: 24, y: 338, width: 352, height: 46)
        place(PanelStyle.label("自动导入"), in: mainPage, x: 24, y: 404, width: 250, height: 20)
        place(mainAutoButton, in: mainPage, x: 340, y: 402, width: 36, height: 22)
    }

    private func setupSettings() {
        place(backButton, in: settingsPage, x: 19, y: 12, width: 32, height: 32)
        backButton.setAccessibilityLabel("返回导入")
        place(PanelStyle.label("设置", size: 17, weight: .semibold), in: settingsPage, x: 63, y: 18, width: 240, height: 24)
        separator(in: settingsPage, y: 55, fullWidth: true)
        let cameraCaption = PanelStyle.label("相机", size: 12)
        cameraCaption.textColor = PanelStyle.muted
        place(cameraCaption, in: settingsPage, x: 24, y: 75, width: 352, height: 18)
        place(cameraPicker, in: settingsPage, x: 24, y: 99, width: 265, height: 30)
        cameraPicker.setAccessibilityLabel("自动导入的相机")
        place(refreshButton, in: settingsPage, x: 296, y: 98, width: 80, height: 30)
        separator(in: settingsPage, y: 140)
        let locationCaption = PanelStyle.label("保存到", size: 12)
        locationCaption.textColor = PanelStyle.muted
        place(locationCaption, in: settingsPage, x: 24, y: 152, width: 352, height: 18)
        place(destinationLabel, in: settingsPage, x: 24, y: 176, width: 263, height: 36)
        destinationLabel.lineBreakMode = .byTruncatingMiddle
        place(destinationButton, in: settingsPage, x: 296, y: 175, width: 80, height: 30)
        destinationButton.setAccessibilityLabel("选择保存目录")
        settingsRow("自动导入", control: autoButton, y: 226)
        settingsRow("同时导入 LRF", control: proxyButton, y: 272)
        settingsRow("登录 Mac 时启动", control: loginButton, y: 318)
        place(summaryLabel, in: settingsPage, x: 24, y: 356, width: 352, height: 18)
        summaryLabel.textColor = PanelStyle.muted
        place(settingsFeedback, in: settingsPage, x: 24, y: 376, width: 352, height: 28)
        settingsFeedback.textColor = PanelStyle.orange
        place(quitButton, in: settingsPage, x: 20, y: 407, width: 145, height: 20)
    }

    private func settingsRow(_ title: String, control: NSButton, y: CGFloat) {
        place(PanelStyle.label(title), in: settingsPage, x: 24, y: y + 2, width: 300, height: 20)
        place(control, in: settingsPage, x: 340, y: y, width: 36, height: 22)
        separator(in: settingsPage, y: y + 34)
    }

    private func place(_ view: NSView, in page: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        view.frame = NSRect(x: x, y: y, width: width, height: height)
        page.addSubview(view)
    }

    private func separator(in page: NSView, y: CGFloat, fullWidth: Bool = false) {
        let line = NSView(frame: NSRect(x: fullWidth ? 0 : 24, y: y, width: fullWidth ? 400 : 352, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = PanelStyle.line.cgColor
        page.addSubview(line)
    }

    static func menuIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            let camera = NSBezierPath()
            camera.move(to: NSPoint(x: 2.5, y: 5.5))
            for point in [(4.0, 5.5), (5, 4), (7, 4), (8, 5.5), (9, 5.5)] { camera.line(to: NSPoint(x: point.0, y: point.1)) }
            camera.curve(to: NSPoint(x: 10.5, y: 7), controlPoint1: NSPoint(x: 9.83, y: 5.5), controlPoint2: NSPoint(x: 10.5, y: 6.17))
            camera.line(to: NSPoint(x: 10.5, y: 11.5))
            camera.curve(to: NSPoint(x: 9, y: 13), controlPoint1: NSPoint(x: 10.5, y: 12.33), controlPoint2: NSPoint(x: 9.83, y: 13))
            camera.line(to: NSPoint(x: 2.5, y: 13))
            camera.curve(to: NSPoint(x: 1, y: 11.5), controlPoint1: NSPoint(x: 1.67, y: 13), controlPoint2: NSPoint(x: 1, y: 12.33))
            camera.line(to: NSPoint(x: 1, y: 7))
            camera.curve(to: NSPoint(x: 2.5, y: 5.5), controlPoint1: NSPoint(x: 1, y: 6.17), controlPoint2: NSPoint(x: 1.67, y: 5.5))
            camera.close()
            let lens = NSBezierPath(ovalIn: NSRect(x: 4, y: 7.5, width: 3.5, height: 3.5))
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 12, y: 9.25)); arrow.line(to: NSPoint(x: 16.5, y: 9.25))
            arrow.move(to: NSPoint(x: 14.25, y: 7)); arrow.line(to: NSPoint(x: 16.5, y: 9.25)); arrow.line(to: NSPoint(x: 14.25, y: 11.5))
            let folder = NSBezierPath()
            folder.move(to: NSPoint(x: 18.5, y: 6.5))
            for point in [(18.5, 4.5), (21.7, 4.5), (23.3, 6.5), (27, 6.5), (27, 13.5), (18.5, 13.5)] { folder.line(to: NSPoint(x: point.0, y: point.1)) }
            folder.close()
            for path in [camera, lens, arrow, folder] {
                path.lineWidth = 1.5
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ActionImport · 相机导入文件夹"
        return image
    }
}
