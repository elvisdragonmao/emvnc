import AppKit
import EmVNCCore
import IOSurface
@preconcurrency import Metal
@preconcurrency import QuartzCore

/// Shows the remote framebuffer and forwards mouse and keyboard input to the session.
///
/// The framebuffer lives in an IOSurface; it is wrapped in a Metal texture without copying and blitted
/// into a `CAMetalLayer` on a render queue, so screen updates never touch SwiftUI or block the main thread.
final class FramebufferView: NSView, FramebufferRenderer {
    weak var session: SessionController?

    var scalingMode: ScalingMode = .fit {
        didSet { needsLayout = true }
    }

    private let imageLayer = CALayer()
    private let renderer = SurfaceRenderer()
    private(set) var framebufferSize: CGSize = .zero
    private var remoteCursor: NSCursor?
    private var trackingArea: NSTrackingArea?
    private var scrollAccumulator = ScrollAccumulator()
    private var buttons: PointerButtons = []

    init(session: SessionController) {
        self.session = session

        super.init(frame: .zero)

        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor.black.cgColor

        imageLayer.contentsGravity = .resize
        imageLayer.isOpaque = true
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.actions = [ "contents": NSNull(), "bounds": NSNull(), "position": NSNull() ]
        layer?.addSublayer(imageLayer)

        if let metalLayer = renderer.layer {
            metalLayer.actions = [ "bounds": NSNull(), "position": NSNull() ]
            layer?.addSublayer(metalLayer)
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Remote screen")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry
    /// Where the framebuffer is drawn: aspect-fit in Fit mode, 1 remote pixel = 1 point in Actual Size.
    var contentRect: CGRect {
        guard framebufferSize.width > 0, framebufferSize.height > 0 else { return .zero }

        switch scalingMode {
            case .actualSize:
                let origin = CGPoint(x: max(0, (bounds.width - framebufferSize.width) / 2),
                                     y: max(0, (bounds.height - framebufferSize.height) / 2))

                return CGRect(origin: origin, size: framebufferSize)
            case .fit:
                let scale = min(bounds.width / framebufferSize.width, bounds.height / framebufferSize.height)
                let size = CGSize(width: (framebufferSize.width * scale).rounded(),
                                  height: (framebufferSize.height * scale).rounded())

                return CGRect(x: ((bounds.width - size.width) / 2).rounded(),
                              y: ((bounds.height - size.height) / 2).rounded(),
                              width: size.width,
                              height: size.height)
        }
    }

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = contentRect
        renderer.layer?.frame = contentRect
        CATransaction.commit()

        window?.invalidateCursorRects(for: self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshContents()
    }

    // MARK: FramebufferRenderer
    func framebufferDidResize(_ size: CGSize) {
        framebufferSize = size
        imageLayer.contents = nil
        refreshContents()
        needsLayout = true
        superview?.needsLayout = true
        (enclosingScrollView?.documentView as? NSView)?.needsLayout = true
        NotificationCenter.default.post(name: Self.framebufferSizeDidChange, object: self)
    }

    func framebufferDidUpdate() {
        refreshContents()
    }

    func cursorDidChange(_ cursor: NSCursor) {
        remoteCursor = cursor
        window?.invalidateCursorRects(for: self)
    }

    static let framebufferSizeDidChange = Notification.Name("EmVNCFramebufferSizeDidChange")

    private func refreshContents() {
        guard let session else { return }

        if renderer.render(surface: session.framebufferSurface, size: framebufferSize) {
            if imageLayer.contents != nil {
                imageLayer.contents = nil
            }
        } else if let image = session.framebufferImage() {
            // Fallback when Metal or a suitable IOSurface is unavailable
            imageLayer.contents = image
        }
    }

    // MARK: Cursor
    override func resetCursorRects() {
        let rect = contentRect.intersection(visibleRect)

        guard !rect.isEmpty else { return }

        addCursorRect(rect, cursor: remoteCursor ?? .arrow)
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(rect: .zero,
                                  options: [ .activeInKeyWindow, .inVisibleRect, .mouseMoved ],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area

        super.updateTrackingAreas()
    }

    // MARK: Mouse
    func framebufferPoint(for event: NSEvent) -> CGPoint? {
        framebufferPoint(forViewPoint: convert(event.locationInWindow, from: nil))
    }

    func framebufferPoint(forViewPoint point: CGPoint) -> CGPoint? {
        let rect = contentRect

        guard rect.width > 0, rect.height > 0 else { return nil }

        let x = (point.x - rect.minX) * framebufferSize.width / rect.width
        let y = (point.y - rect.minY) * framebufferSize.height / rect.height

        return CGPoint(x: min(max(0, x), framebufferSize.width - 1),
                       y: min(max(0, y), framebufferSize.height - 1))
    }

    private func sendPointer(_ event: NSEvent) {
        guard let point = framebufferPoint(for: event) else { return }

        session?.pointer(at: point, buttons: buttons)
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttons.insert(.left)
        sendPointer(event)
    }

    override func mouseUp(with event: NSEvent) {
        buttons.remove(.left)
        sendPointer(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttons.insert(.right)
        sendPointer(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        buttons.remove(.right)
        sendPointer(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }

        buttons.insert(.middle)
        sendPointer(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }

        buttons.remove(.middle)
        sendPointer(event)
    }

    override func scrollWheel(with event: NSEvent) {
        // In Actual Size the scroll view scrolls the local viewport when the remote screen is larger
        if scalingMode == .actualSize, event.modifierFlags.contains(.option) {
            super.scrollWheel(with: event)
            return
        }

        guard let point = framebufferPoint(for: event) else { return }

        if event.phase == .began {
            scrollAccumulator.reset()
        }

        let steps = scrollAccumulator.steps(deltaX: event.scrollingDeltaX,
                                            deltaY: event.scrollingDeltaY,
                                            isPrecise: event.hasPreciseScrollingDeltas)

        for (direction, count) in steps {
            session?.scroll(direction, steps: min(count, 10), at: point)
        }
    }

    // MARK: Keyboard
    override func keyDown(with event: NSEvent) {
        guard let session, session.phase.isConnected else {
            // Let the status overlay's buttons (Return = Try Again, Esc = Cancel) handle the key
            super.keyDown(with: event)
            return
        }

        session.keyDown(KeyInput(event))
    }

    override func keyUp(with event: NSEvent) {
        guard let session, session.phase.isConnected else {
            super.keyUp(with: event)
            return
        }

        session.keyUp(KeyInput(event))
    }

    override func flagsChanged(with event: NSEvent) {
        session?.modifiersChanged(keyCode: event.keyCode, modifierFlags: event.modifierFlags.rawValue)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.firstResponder === self,
              let session,
              session.phase.isConnected else {
            return super.performKeyEquivalent(with: event)
        }

        let route = ShortcutRouter.route(charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                                         modifierFlags: event.modifierFlags.rawValue,
                                         passthrough: session.preferences.shortcutPassthrough)

        if route == .localFirst, NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            session.keyEquivalentHandledLocally()
            return true
        }

        session.keyEquivalent(KeyInput(event))

        return true
    }

    override func resignFirstResponder() -> Bool {
        session?.releaseAllKeys()
        buttons = []

        return super.resignFirstResponder()
    }
}

extension KeyInput {
    init(_ event: NSEvent) {
        self.init(keyCode: event.keyCode, charactersIgnoringModifiers: event.charactersIgnoringModifiers)
    }
}

/// Hosts the framebuffer view in a scroll view so Actual Size can scroll; in Fit mode the document view
/// simply tracks the visible area.
final class RemoteScreenView: NSView {
    let framebufferView: FramebufferView
    private let scrollView = NSScrollView()
    private let clipView = CenteringClipView()

    var scalingMode: ScalingMode {
        get { framebufferView.scalingMode }
        set {
            framebufferView.scalingMode = newValue
            updateScrolling()
        }
    }

    init(session: SessionController) {
        self.framebufferView = FramebufferView(session: session)

        super.init(frame: .zero)

        scrollView.contentView = clipView
        scrollView.documentView = framebufferView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(framebufferSizeChanged),
                                               name: FramebufferView.framebufferSizeDidChange,
                                               object: framebufferView)
        updateScrolling()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func framebufferSizeChanged() {
        updateScrolling()
    }

    override func layout() {
        super.layout()
        updateDocumentSize()
    }

    private func updateScrolling() {
        let scrolls = scalingMode == .actualSize

        scrollView.hasHorizontalScroller = scrolls
        scrollView.hasVerticalScroller = scrolls
        updateDocumentSize()
    }

    private func updateDocumentSize() {
        let visible = scrollView.contentSize

        switch scalingMode {
            case .fit:
                framebufferView.frame = CGRect(origin: .zero, size: visible)
            case .actualSize:
                let size = framebufferView.framebufferSize
                framebufferView.frame = CGRect(x: 0, y: 0,
                                               width: max(size.width, visible.width),
                                               height: max(size.height, visible.height))
        }

        framebufferView.needsLayout = true
    }
}

/// Keeps a smaller document centred instead of pinned to a corner.
private final class CenteringClipView: NSClipView {
    override var isFlipped: Bool { true }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)

        guard let documentView else { return rect }

        if rect.width > documentView.frame.width {
            rect.origin.x = (documentView.frame.width - rect.width) / 2
        }

        if rect.height > documentView.frame.height {
            rect.origin.y = (documentView.frame.height - rect.height) / 2
        }

        return rect
    }
}

/// Blits an IOSurface-backed framebuffer into a CAMetalLayer. All Metal work happens on a serial queue;
/// if a frame is still in flight the next update is skipped (the following one carries the latest pixels).
private final class SurfaceRenderer: @unchecked Sendable {
    let layer: CAMetalLayer?

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let queue = DispatchQueue(label: "dev.emvnc.framebuffer-render", qos: .userInteractive)
    private let inFlight = DispatchSemaphore(value: 1)
    private let lock = NSLock()
    private var texture: MTLTexture?
    private var textureSurface: IOSurface?
    private var pendingRender = false

    init() {
        let device = MTLCreateSystemDefaultDevice()

        self.device = device
        self.commandQueue = device?.makeCommandQueue()

        if let device {
            let layer = CAMetalLayer()
            layer.device = device
            layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly = false
            layer.isOpaque = true
            layer.contentsGravity = .resize
            layer.magnificationFilter = .linear
            layer.minificationFilter = .linear
            layer.allowsNextDrawableTimeout = true
            self.layer = layer
        } else {
            self.layer = nil
        }
    }

    /// Returns false when this surface cannot be drawn with Metal (caller falls back to CGImage).
    @MainActor
    func render(surface: IOSurface?, size: CGSize) -> Bool {
        guard let layer, let device, commandQueue != nil,
              let surface, size.width > 0, size.height > 0,
              surface.bytesPerRow % 16 == 0,
              surface.width == Int(size.width), surface.height == Int(size.height) else {
            layer?.isHidden = true
            return false
        }

        layer.isHidden = false

        if layer.drawableSize != size {
            layer.drawableSize = size
        }

        lock.lock()
        if textureSurface !== surface {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                      width: Int(size.width),
                                                                      height: Int(size.height),
                                                                      mipmapped: false)
            descriptor.usage = [ .shaderRead ]
            descriptor.storageMode = .shared
            texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
            textureSurface = surface
        }
        let texture = self.texture
        lock.unlock()

        guard let texture else {
            layer.isHidden = true
            return false
        }

        guard inFlight.wait(timeout: .now()) == .success else {
            return true
        }

        // CAMetalLayer.nextDrawable() and Metal command encoding are safe off the main thread
        nonisolated(unsafe) let metalLayer = layer
        nonisolated(unsafe) let sourceTexture = texture

        queue.async { [self] in
            defer { inFlight.signal() }

            let layer = metalLayer
            let texture = sourceTexture

            guard let drawable = layer.nextDrawable(),
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let blit = commandBuffer.makeBlitCommandEncoder() else {
                return
            }

            let width = min(texture.width, drawable.texture.width)
            let height = min(texture.height, drawable.texture.height)

            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        return true
    }
}
