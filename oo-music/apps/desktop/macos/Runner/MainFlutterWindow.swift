import Cocoa
import FlutterMacOS

/// 桌面歌词窗口的尺寸和排版档位。
private enum DesktopLyricsSizing {
  static let minWidth: CGFloat = 460
  static let maxWidth: CGFloat = 800
  static let defaultWidth: CGFloat = 620
  static let height: CGFloat = 118

  static func lyricFontSize(forWidth width: CGFloat) -> CGFloat {
    let clampedWidth = min(max(width, minWidth), maxWidth)
    if clampedWidth < 520 { return 18 }
    if clampedWidth < 570 { return 20 }
    if clampedWidth < 620 { return 22 }
    if clampedWidth < 670 { return 24 }
    if clampedWidth < 720 { return 26 }
    if clampedWidth < 760 { return 28 }
    return 30
  }

  static func translationFontSize(forLyricSize size: CGFloat) -> CGFloat {
    min(18, max(13, (size * 0.56).rounded()))
  }
}

class MainFlutterWindow: NSWindow {
  private var desktopLyricsChannel: FlutterMethodChannel?
  private var desktopLyricsWindowController: DesktopLyricsWindowController?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.setContentSize(NSSize(width: 1180, height: 780))
    self.minSize = NSSize(width: 980, height: 640)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    let lyricsController = DesktopLyricsWindowController()
    desktopLyricsWindowController = lyricsController
    let channel = FlutterMethodChannel(
      name: "oo_music/desktop_lyrics",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    desktopLyricsChannel = channel
    lyricsController.onClose = { [weak channel] in
      channel?.invokeMethod("closed", arguments: nil)
    }
    lyricsController.onPrevious = { [weak channel] in
      channel?.invokeMethod("previous", arguments: nil)
    }
    lyricsController.onTogglePlayback = { [weak channel] in
      channel?.invokeMethod("togglePlayback", arguments: nil)
    }
    lyricsController.onNext = { [weak channel] in
      channel?.invokeMethod("next", arguments: nil)
    }
    configureDesktopLyricsMenu()
    channel.setMethodCallHandler { [weak lyricsController] call, result in
      guard let lyricsController else {
        result(FlutterError(code: "unavailable", message: "桌面歌词窗口不可用", details: nil))
        return
      }
      let arguments = call.arguments as? [String: Any] ?? [:]
      let lyric = arguments["lyric"] as? String ?? ""
      let translation = arguments["translation"] as? String ?? ""
      let isPlaying = arguments["isPlaying"] as? Bool ?? false
      switch call.method {
      case "show":
        lyricsController.show(
          lyric: lyric,
          translation: translation,
          isPlaying: isPlaying
        )
        result(true)
      case "update":
        lyricsController.update(
          lyric: lyric,
          translation: translation,
          isPlaying: isPlaying
        )
        result(nil)
      case "hide":
        lyricsController.hide()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  @objc private func toggleDesktopLyricsFromMenu() {
    desktopLyricsChannel?.invokeMethod("toggle", arguments: nil)
  }

  private func configureDesktopLyricsMenu() {
    guard let mainMenu = NSApp.mainMenu,
          let viewMenu = mainMenu.items.first(where: { $0.title == "View" })?.submenu else {
      return
    }

    let toggleItem = NSMenuItem(
      title: "显示/关闭桌面歌词",
      action: #selector(toggleDesktopLyricsFromMenu),
      keyEquivalent: "l"
    )
    toggleItem.keyEquivalentModifierMask = [.command, .shift]
    toggleItem.target = self
    viewMenu.insertItem(toggleItem, at: 0)
    viewMenu.insertItem(NSMenuItem.separator(), at: 1)
  }
}

/// 管理一个不激活应用、始终置顶的原生桌面歌词窗口。
private final class DesktopLyricsWindowController: NSObject, NSWindowDelegate {
  var onClose: (() -> Void)?
  var onPrevious: (() -> Void)?
  var onTogglePlayback: (() -> Void)?
  var onNext: (() -> Void)?

  private let panel: NSPanel
  private let hoverView = DesktopLyricsHoverView()
  private let backgroundView = DesktopLyricsBackgroundView()
  private let lyricLabel = PassthroughTextField()
  private let translationLabel = PassthroughTextField()
  private let controlsStack = NSStackView()
  private let transportStack = NSStackView()
  private let lockButton = NSButton()
  private let closeButton = NSButton()
  private let previousButton = NSButton()
  private let playbackButton = NSButton()
  private let nextButton = NSButton()
  private let resizeHandle = DesktopLyricsResizeHandle(frame: .zero)
  private var hasPositioned = false
  private var isHovered = false
  private var isLocked = false
  private var isPlaying = false
  private var dragStartFrame = NSRect.zero

  override init() {
    panel = NSPanel(
      contentRect: NSRect(
        x: 0,
        y: 0,
        width: DesktopLyricsSizing.defaultWidth,
        height: DesktopLyricsSizing.height
      ),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    super.init()
    configurePanel()
    configureContent()
  }

  func show(lyric: String, translation: String, isPlaying: Bool) {
    update(lyric: lyric, translation: translation, isPlaying: isPlaying)
    if !hasPositioned, let screen = NSScreen.main {
      let visibleFrame = screen.visibleFrame
      let origin = NSPoint(
        x: visibleFrame.midX - panel.frame.width / 2,
        y: visibleFrame.minY + 72
      )
      panel.setFrameOrigin(origin)
      hasPositioned = true
    }
    panel.orderFrontRegardless()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      setHovered(panel.frame.contains(NSEvent.mouseLocation))
    }
  }

  func update(lyric: String, translation: String, isPlaying: Bool) {
    lyricLabel.stringValue = lyric.isEmpty ? "oo music" : lyric
    translationLabel.stringValue = translation
    translationLabel.isHidden = translation.isEmpty
    self.isPlaying = isPlaying
    applyLabelAppearance()
    updatePlaybackSymbol()
  }

  func hide() {
    isHovered = false
    refreshChrome(animated: false)
    panel.orderOut(nil)
  }

  private func configurePanel() {
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    // 透明面板的移动和缩宽都由歌词内容视图自己处理，避免系统背景拖动
    // 抢占右侧缩放把手的鼠标事件。
    panel.isMovableByWindowBackground = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.delegate = self
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
  }

  private func configureContent() {
    hoverView.frame = NSRect(
      x: 0,
      y: 0,
      width: DesktopLyricsSizing.defaultWidth,
      height: DesktopLyricsSizing.height
    )
    hoverView.autoresizingMask = [.width, .height]
    hoverView.onHoverChanged = { [weak self] hovered in
      self?.setHovered(hovered)
    }
    hoverView.canBeginDrag = { [weak self] operation in
      guard let self else { return false }
      guard !self.isLocked else { return false }
      return operation == .move || self.canResizeLyricsWindow
    }
    hoverView.onDragBegan = { [weak self] _ in
      self?.dragStartFrame = self?.panel.frame ?? .zero
    }
    hoverView.onDragChanged = { [weak self] operation, delta in
      guard let self else { return }
      switch operation {
      case .move:
        self.panel.setFrameOrigin(NSPoint(
          x: self.dragStartFrame.origin.x + delta.x,
          y: self.dragStartFrame.origin.y + delta.y
        ))
      case .resize:
        self.resizeWindow(toWidth: self.dragStartFrame.width + delta.x)
      }
    }
    panel.contentView = hoverView

    backgroundView.frame = hoverView.bounds
    backgroundView.autoresizingMask = [.width, .height]
    backgroundView.wantsLayer = true
    backgroundView.layer?.backgroundColor = NSColor(
      calibratedRed: 0.10,
      green: 0.13,
      blue: 0.15,
      alpha: 0.96
    ).cgColor
    backgroundView.layer?.cornerRadius = 18
    backgroundView.layer?.masksToBounds = true
    backgroundView.layer?.borderWidth = 1
    backgroundView.layer?.borderColor = NSColor(
      calibratedRed: 0.075,
      green: 0.098,
      blue: 0.112,
      alpha: 1
    ).cgColor
    backgroundView.alphaValue = 0
    backgroundView.isHidden = true
    hoverView.addSubview(backgroundView)

    configureLabel(
      lyricLabel,
      fontSize: 27,
      weight: .semibold,
      color: NSColor(calibratedRed: 0.70, green: 0.86, blue: 0.79, alpha: 1)
    )
    configureLabel(
      translationLabel,
      fontSize: 15,
      weight: .regular,
      color: NSColor(calibratedRed: 0.72, green: 0.76, blue: 0.75, alpha: 1)
    )

    configureControls()

    let textStack = PassthroughStackView(views: [lyricLabel, translationLabel])
    textStack.orientation = .vertical
    textStack.alignment = .centerX
    textStack.spacing = 5
    textStack.detachesHiddenViews = true
    textStack.translatesAutoresizingMaskIntoConstraints = false
    hoverView.addSubview(textStack)

    resizeHandle.translatesAutoresizingMaskIntoConstraints = false
    resizeHandle.toolTip = "拖动调整歌词窗口宽度"
    resizeHandle.alphaValue = 0
    hoverView.addSubview(resizeHandle)

    NSLayoutConstraint.activate([
      controlsStack.topAnchor.constraint(equalTo: hoverView.topAnchor, constant: 8),
      controlsStack.centerXAnchor.constraint(equalTo: hoverView.centerXAnchor),
      controlsStack.heightAnchor.constraint(equalToConstant: 30),

      textStack.leadingAnchor.constraint(equalTo: hoverView.leadingAnchor, constant: 46),
      textStack.trailingAnchor.constraint(equalTo: hoverView.trailingAnchor, constant: -46),
      textStack.topAnchor.constraint(equalTo: controlsStack.bottomAnchor, constant: 4),
      textStack.bottomAnchor.constraint(lessThanOrEqualTo: hoverView.bottomAnchor, constant: -10),

      resizeHandle.trailingAnchor.constraint(equalTo: hoverView.trailingAnchor),
      resizeHandle.topAnchor.constraint(equalTo: hoverView.topAnchor),
      resizeHandle.bottomAnchor.constraint(equalTo: hoverView.bottomAnchor),
      resizeHandle.widthAnchor.constraint(equalToConstant: DesktopLyricsHoverView.resizeHitWidth),
    ])

    updateTypography()
    refreshChrome(animated: false)
  }

  private func configureControls() {
    configureSymbolButton(
      previousButton,
      symbol: "backward.end.fill",
      tooltip: "上一首",
      action: #selector(previousPressed)
    )
    configureSymbolButton(
      playbackButton,
      symbol: "play.fill",
      tooltip: "播放",
      action: #selector(playbackPressed)
    )
    configureSymbolButton(
      nextButton,
      symbol: "forward.end.fill",
      tooltip: "下一首",
      action: #selector(nextPressed)
    )
    configureSymbolButton(
      lockButton,
      symbol: "lock.open.fill",
      tooltip: "锁定桌面歌词",
      action: #selector(lockPressed)
    )
    configureSymbolButton(
      closeButton,
      symbol: "xmark",
      tooltip: "关闭桌面歌词",
      action: #selector(closePressed)
    )

    transportStack.orientation = .horizontal
    transportStack.alignment = .centerY
    transportStack.spacing = 2
    transportStack.addArrangedSubview(previousButton)
    transportStack.addArrangedSubview(playbackButton)
    transportStack.addArrangedSubview(nextButton)

    let separator = NSBox()
    separator.boxType = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false
    separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
    separator.heightAnchor.constraint(equalToConstant: 16).isActive = true

    controlsStack.orientation = .horizontal
    controlsStack.alignment = .centerY
    controlsStack.spacing = 7
    controlsStack.translatesAutoresizingMaskIntoConstraints = false
    controlsStack.addArrangedSubview(transportStack)
    controlsStack.addArrangedSubview(separator)
    controlsStack.addArrangedSubview(lockButton)
    controlsStack.addArrangedSubview(closeButton)
    controlsStack.setCustomSpacing(11, after: transportStack)
    controlsStack.setCustomSpacing(8, after: separator)
    controlsStack.alphaValue = 0
    controlsStack.isHidden = true
    hoverView.addSubview(controlsStack)
  }

  private func configureSymbolButton(
    _ button: NSButton,
    symbol: String,
    tooltip: String,
    action: Selector
  ) {
    button.target = self
    button.action = action
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.focusRingType = .none
    button.contentTintColor = NSColor(calibratedWhite: 0.72, alpha: 0.92)
    button.toolTip = tooltip
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 28).isActive = true
    button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    button.wantsLayer = true
    button.layer?.shadowColor = NSColor.black.cgColor
    button.layer?.shadowOpacity = 0.45
    button.layer?.shadowRadius = 2
    button.layer?.shadowOffset = NSSize(width: 0, height: -1)
    setSymbol(symbol, on: button)
  }

  private func setSymbol(_ name: String, on button: NSButton) {
    let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
    button.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration)
  }

  private func updatePlaybackSymbol() {
    setSymbol(isPlaying ? "pause.fill" : "play.fill", on: playbackButton)
    playbackButton.toolTip = isPlaying ? "暂停" : "播放"
  }

  private func updateTypography() {
    let fontSize = DesktopLyricsSizing.lyricFontSize(forWidth: panel.frame.width)
    let translationSize = DesktopLyricsSizing.translationFontSize(
      forLyricSize: fontSize
    )
    lyricLabel.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    translationLabel.font = NSFont.systemFont(ofSize: translationSize, weight: .regular)
    applyLabelAppearance()
  }

  private var canResizeLyricsWindow: Bool {
    guard let screen = panel.screen else { return true }
    return screen.visibleFrame.maxX - panel.frame.minX > DesktopLyricsSizing.minWidth
  }

  private func resizeWindow(toWidth requestedWidth: CGFloat) {
    guard !isLocked else { return }
    var frame = panel.frame
    let availableWidth: CGFloat
    if let screen = panel.screen {
      availableWidth = screen.visibleFrame.maxX - frame.minX - 8
    } else {
      availableWidth = DesktopLyricsSizing.maxWidth
    }
    let maximumWidth = max(
      DesktopLyricsSizing.minWidth,
      min(DesktopLyricsSizing.maxWidth, availableWidth)
    )
    let nextWidth = min(
      maximumWidth,
      max(DesktopLyricsSizing.minWidth, requestedWidth)
    )
    guard abs(nextWidth - frame.width) > 0.5 else { return }
    frame.size.width = nextWidth
    panel.setFrame(frame, display: true)
    updateTypography()
  }

  private func configureLabel(
    _ label: NSTextField,
    fontSize: CGFloat,
    weight: NSFont.Weight,
    color: NSColor
  ) {
    label.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
    label.textColor = color
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.isEditable = false
    label.isSelectable = false
    label.isBezeled = false
    label.isBordered = false
    label.drawsBackground = false
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.shadow = nil
  }

  private func applyLabelAppearance() {
    // Keep glyphs as solid fills and use only a one-point darker edge. No soft
    // shadow or multi-layer halo remains in any window state.
    styleLabel(lyricLabel)
    styleLabel(translationLabel)
  }

  private func styleLabel(_ label: NSTextField) {
    guard let font = label.font, let color = label.textColor else { return }
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byTruncatingTail
    let strokeWidth = -100.0 / max(font.pointSize, 1)
    label.attributedStringValue = NSAttributedString(
      string: label.stringValue,
      attributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
        .strokeColor: darkerColor(color, factor: 0.72),
        .strokeWidth: strokeWidth,
      ]
    )
    label.shadow = nil
  }

  private func darkerColor(_ color: NSColor, factor: CGFloat) -> NSColor {
    guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
    return NSColor(
      calibratedRed: rgb.redComponent * factor,
      green: rgb.greenComponent * factor,
      blue: rgb.blueComponent * factor,
      alpha: 0.94
    )
  }

  private func setHovered(_ hovered: Bool) {
    guard isHovered != hovered else { return }
    isHovered = hovered
    refreshChrome(animated: true)
  }

  private func refreshChrome(animated: Bool) {
    transportStack.isHidden = isLocked
    closeButton.isHidden = isLocked
    lockButton.isHidden = false
    setSymbol(isLocked ? "lock.fill" : "lock.open.fill", on: lockButton)
    lockButton.toolTip = isLocked ? "解锁桌面歌词" : "锁定桌面歌词"

    let showsControls = isHovered
    let showsBackground = isHovered && !isLocked
    let showsResizeHandle = isHovered && !isLocked
    hoverView.invalidateResizeCursor()
    if showsControls {
      controlsStack.isHidden = false
    }
    if showsBackground {
      backgroundView.isHidden = false
    }
    let changes = {
      self.controlsStack.animator().alphaValue = showsControls ? 1 : 0
      self.backgroundView.animator().alphaValue = showsBackground ? 1 : 0
      self.resizeHandle.animator().alphaValue = showsResizeHandle ? 1 : 0
    }
    guard animated else {
      changes()
      controlsStack.alphaValue = showsControls ? 1 : 0
      backgroundView.alphaValue = showsBackground ? 1 : 0
      resizeHandle.alphaValue = showsResizeHandle ? 1 : 0
      controlsStack.isHidden = !showsControls
      backgroundView.isHidden = !showsBackground
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = showsControls || showsBackground ? 0.18 : 0.14
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      changes()
    } completionHandler: { [weak self] in
      guard let self else { return }
      if !isHovered {
        controlsStack.isHidden = true
      }
      if !isHovered || isLocked {
        backgroundView.isHidden = true
      }
    }
  }

  func windowDidResize(_ notification: Notification) {
    updateTypography()
  }

  @objc private func previousPressed() {
    guard !isLocked else { return }
    onPrevious?()
  }

  @objc private func playbackPressed() {
    guard !isLocked else { return }
    onTogglePlayback?()
  }

  @objc private func nextPressed() {
    guard !isLocked else { return }
    onNext?()
  }

  @objc private func lockPressed() {
    isLocked.toggle()
    hoverView.invalidateResizeCursor()
    refreshChrome(animated: true)
  }

  @objc private func closePressed() {
    hide()
    onClose?()
  }
}

/// 始终接收鼠标进出事件，让透明歌词窗口只在悬停时展示控制层。
private final class DesktopLyricsHoverView: NSView {
  enum DragOperation {
    case move
    case resize
  }

  static let resizeHitWidth: CGFloat = 24

  var onHoverChanged: ((Bool) -> Void)?
  var canBeginDrag: ((DragOperation) -> Bool)?
  var onDragBegan: ((DragOperation) -> Void)?
  var onDragChanged: ((DragOperation, NSPoint) -> Void)?

  private var hoverTrackingArea: NSTrackingArea?
  private var dragOperation: DragOperation?
  private var dragStartGlobalLocation: NSPoint?

  override var mouseDownCanMoveWindow: Bool {
    false
  }

  override func updateTrackingAreas() {
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    hoverTrackingArea = trackingArea
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    invalidateResizeCursor()
    onHoverChanged?(true)
  }

  override func mouseExited(with event: NSEvent) {
    onHoverChanged?(false)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    if isInResizeZone(point), canBeginDrag?(.resize) == true {
      return self
    }
    return super.hitTest(point)
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard canBeginDrag?(.resize) == true else { return }
    addCursorRect(resizeZone, cursor: .resizeLeftRight)
  }

  override func mouseDown(with event: NSEvent) {
    let location = convert(event.locationInWindow, from: nil)
    let operation: DragOperation?
    if isInResizeZone(location), canBeginDrag?(.resize) == true {
      operation = .resize
    } else if canBeginDrag?(.move) == true {
      operation = .move
    } else {
      operation = nil
    }
    guard let operation else { return }
    dragOperation = operation
    dragStartGlobalLocation = NSEvent.mouseLocation
    onDragBegan?(operation)
  }

  override func mouseDragged(with event: NSEvent) {
    guard
      let dragOperation,
      let dragStartGlobalLocation
    else { return }
    let currentLocation = NSEvent.mouseLocation
    let delta = NSPoint(
      x: currentLocation.x - dragStartGlobalLocation.x,
      y: currentLocation.y - dragStartGlobalLocation.y
    )
    onDragChanged?(dragOperation, delta)
  }

  override func mouseUp(with event: NSEvent) {
    dragOperation = nil
    dragStartGlobalLocation = nil
    invalidateResizeCursor()
  }

  func invalidateResizeCursor() {
    window?.invalidateCursorRects(for: self)
  }

  private var resizeZone: NSRect {
    NSRect(
      x: bounds.maxX - Self.resizeHitWidth,
      y: bounds.minY,
      width: Self.resizeHitWidth,
      height: bounds.height
    )
  }

  private func isInResizeZone(_ point: NSPoint) -> Bool {
    resizeZone.contains(point)
  }
}

/// 透明窗口右侧的横向缩放把手。鼠标事件由歌词内容视图统一处理。
private final class DesktopLyricsResizeHandle: NSView {
  private let iconView = NSImageView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor

    let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    iconView.image = NSImage(
      systemSymbolName: "arrow.left.and.right",
      accessibilityDescription: "调整歌词窗口宽度"
    )?.withSymbolConfiguration(configuration)
    iconView.contentTintColor = NSColor(calibratedWhite: 0.78, alpha: 0.96)
    iconView.imageScaling = .scaleProportionallyDown
    iconView.wantsLayer = true
    iconView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.14).cgColor
    iconView.layer?.cornerRadius = 6
    iconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconView)

    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 20),
      iconView.heightAnchor.constraint(equalToConstant: 32),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

/// 纯色背景不参与命中测试，保证歌词空白区域可以拖动窗口。
private final class DesktopLyricsBackgroundView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

/// 歌词文本布局不拦截鼠标事件，避免歌词区域变成不可拖动区域。
private final class PassthroughStackView: NSStackView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

/// 文本不抢占鼠标事件，窗口任意空白区域都可以直接拖动。
private final class PassthroughTextField: NSTextField {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}
