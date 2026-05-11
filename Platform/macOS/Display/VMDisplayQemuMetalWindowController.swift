//
// Copyright © 2020 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import CocoaSpiceRenderer
import Carbon.HIToolbox
import SwiftUI

class VMDisplayQemuMetalWindowController: VMDisplayQemuWindowController {
    var metalView: VMMetalView!
    var renderer: CSMetalRenderer!

    private var vmDisplay: CSDisplay? {
        didSet {
            if let renderer = renderer {
                oldValue?.removeRenderer(renderer)
                vmDisplay?.addRenderer(renderer)
            }
            teardownSeamlessCursor(on: oldValue)
            setupSeamlessCursor(on: vmDisplay)
        }
    }
    private var vmInput: CSInput?
    private var cursorObservations: [NSKeyValueObservation] = []
    private var lastCursorSize: CGSize = .zero
    private var lastCursorHotspot: CGPoint = .zero
    
    private var displaySize: CGSize = .zero
    private var isDisplaySizeDynamic: Bool = false
    private var isFullScreen: Bool = false
    private let minDynamicSize = CGSize(width: 800, height: 600)
    private let resizeDebounceSecs: Double = 1
    private let resizeTimeoutSecs: Double = 5
    private var debounceResize: DispatchWorkItem?
    private var cancelResize: DispatchWorkItem?
    
    private var localEventMonitor: Any? = nil
    private var globalEventMonitor: Any? = nil
    private var ctrlKeyDown: Bool = false
    private var screenChangedToken: Any?

    private var displayConfig: UTMQemuConfigurationDisplay? {
        vmQemuConfig?.displays[id]
    }
    
    override var defaultTitle: String {
        if isSecondary {
            return String.localizedStringWithFormat(NSLocalizedString("%@ (Display %lld)", comment: "VMDisplayMetalWindowController"), vmQemuConfig.information.name, id + 1)
        } else {
            return super.defaultTitle
        }
    }
    
    // MARK: - User preferences
    
    @Setting("NoCursorCaptureAlert") private var isCursorCaptureAlertShown: Bool = false
    @Setting("NoFullscreenCursorCaptureAlert") private var isFullscreenCursorCaptureAlertShown: Bool = false
    @Setting("FullScreenAutoCapture") private var isFullScreenAutoCapture: Bool = false
    @Setting("WindowFocusAutoCapture") private var isWindowFocusAutoCapture: Bool = false
    @Setting("CtrlRightClick") private var isCtrlRightClick: Bool = false
    @Setting("AlternativeCaptureKey") private var isAlternativeCaptureKey: Bool = false
    @Setting("IsCapsLockKey") private var isCapsLockKey: Bool = false
    @Setting("IsNumLockForced") private var isNumLockForced: Bool = false
    @Setting("InvertScroll") private var isInvertScroll: Bool = false
    @Setting("QEMURendererFPSLimit") private var rendererFpsLimit: Int = 0
    
    // MARK: - Init
    
    convenience init(secondaryFromDisplay display: CSDisplay, primary: VMDisplayQemuMetalWindowController, vm: UTMQemuVirtualMachine, id: Int) {
        self.init(vm: vm, id: id)
        self.vmDisplay = display
        self.vmInput = primary.vmInput
        self.isDisplaySizeDynamic = primary.isDisplaySizeDynamic
    }
    
    override func windowDidLoad() {
        metalView = VMMetalView(frame: displayView.bounds)
        metalView.autoresizingMask = [.width, .height]
        metalView.device = MTLCreateSystemDefaultDevice()
        guard let _ = metalView.device else {
            showErrorAlert(NSLocalizedString("Metal is not supported on this device. Cannot render display.", comment: "VMDisplayMetalWindowController"))
            logger.critical("Cannot find system default Metal device.")
            return
        }
        // Reduce CAMetalLayer's drawable pool from the default 3 to 2.
        // Triple-buffering adds up to one frame of host-side queue
        // latency; cutting to two halves the worst-case wait at the
        // cost of dropping a frame if rendering misses vsync. For a
        // simple texture blit (the guest framebuffer) this is fine and
        // saves ~8.3ms at 120Hz on the input-to-photon path.
        // See Apple devforum thread 711033 + Flutter Impeller #138490.
        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = 2
        }
        displayView.addSubview(metalView)
        renderer = CSMetalRenderer.init(metalKitView: metalView)
        guard let renderer = self.renderer else {
            showErrorAlert(NSLocalizedString("Internal error.", comment: "VMDisplayMetalWindowController"))
            logger.critical("Failed to create renderer.")
            return
        }
        // FPS preference: at windowDidLoad time `self.window?.screen` is
        // often nil because the window hasn't been placed on a screen
        // yet, so the maxFps branch falls through and MTKView keeps its
        // default of 60 — even on a 120Hz panel. Use NSScreen.main as the
        // fallback so we always set something, and re-check when the
        // window's screen changes (see screenChangedToken below).
        applyPreferredFps()
        renderer.changeUpscaler(displayConfig?.upscalingFilter.metalSamplerMinMagFilter ?? .linear, downscaler: displayConfig?.downscalingFilter.metalSamplerMinMagFilter ?? .linear)
        vmDisplay?.addRenderer(renderer) // can be nil if primary
        metalView.delegate = renderer
        metalView.inputDelegate = self

        screenChangedToken = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main) { [weak self] _ in
            // update minSize when we change screens
            if let self = self,
               let window = window,
               displaySize != .zero,
               !isDisplaySizeDynamic {
                window.contentMinSize = contentMinSize(in: window, for: displaySize)
            }
            // Re-apply the FPS preference now that we know which screen
            // we're on (windowDidLoad fires before the window is placed).
            self?.applyPreferredFps()
        }

        if isSecondary && isDisplaySizeDynamic, let window = window {
            restoreDynamicResolution(for: window)
        }

        super.windowDidLoad()
    }

    private func applyPreferredFps() {
        guard let metalView = metalView else { return }
        if rendererFpsLimit > 0 {
            metalView.preferredFramesPerSecond = rendererFpsLimit
            return
        }
        // window.screen is nil before placement; fall through to NSScreen.main
        // (typically the same display) instead of leaving MTKView at its
        // 60Hz default — that floor is the dominant input-lag contributor
        // on a 120Hz MBP. maximumFramesPerSecond is macOS 12+ only.
        if #available(macOS 12, *) {
            let maxFps = self.window?.screen?.maximumFramesPerSecond
                ?? NSScreen.main?.maximumFramesPerSecond
                ?? 60
            metalView.preferredFramesPerSecond = maxFps
        }
    }

    // MARK: - Seamless cursor sync
    //
    // Mirrors the guest's cursor shape (I-beam over text, hand over links,
    // resize, busy spinner, etc.) onto macOS's NSCursor so the user sees
    // the snappy host-rendered pointer with the guest's contextual shape.
    // The guest's own cursor sprite is inhibited (isInhibited=true) so
    // there's no laggy duplicate in the framebuffer.

    private func setupSeamlessCursor(on display: CSDisplay?) {
        seamlessLog("setupSeamlessCursor display=\(display != nil ? "set" : "nil") cursor=\(display?.cursor != nil ? "set" : "nil")")
        guard let display = display else { return }
        // The cursor is a weak property on CSDisplay and attaches asynchronously
        // when the SPICE cursor channel connects, which is typically AFTER
        // vmDisplay is set. Observe it so we set up the inner KVO once it
        // appears.
        let cursorAttachObs = display.observe(\.cursor, options: [.new, .initial]) { [weak self] d, _ in
            self?.seamlessLog("cursor attach KVO fired: cursor=\(d.cursor != nil ? "set" : "nil")")
            self?.attachCursorObservers(d.cursor)
        }
        cursorObservations = [cursorAttachObs]
    }

    private func attachCursorObservers(_ cursor: CSCursor?) {
        // Remove inner observers (size + hotspot) but keep the outer
        // display.cursor observer alive.
        for o in cursorObservations.dropFirst() { o.invalidate() }
        cursorObservations = Array(cursorObservations.prefix(1))
        guard let cursor = cursor else { return }

        cursor.isInhibited = true
        seamlessLog("attached observers, isInhibited=\(cursor.isInhibited)")
        let sizeObs = cursor.observe(\.cursorSize, options: [.new, .initial]) { [weak self] c, _ in
            self?.seamlessLog("KVO cursorSize fired: \(c.cursorSize)")
            self?.applyGuestCursor(from: c)
        }
        let hotObs = cursor.observe(\.cursorHotspot, options: [.new]) { [weak self] c, _ in
            self?.seamlessLog("KVO cursorHotspot fired: \(c.cursorHotspot)")
            self?.applyGuestCursor(from: c)
        }
        cursorObservations.append(contentsOf: [sizeObs, hotObs])

        // Diagnostic poll: KVO may be the problem. Poll cursor every
        // 500ms for 30 seconds and log non-zero sizes.
        let weakCursor = cursor
        for i in 1...60 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(i)) { [weak self, weak weakCursor] in
                guard let self = self, let c = weakCursor else { return }
                if c.cursorSize != .zero {
                    self.seamlessLog("POLL t=\(i): cursorSize=\(c.cursorSize) hotspot=\(c.cursorHotspot) texture=\(c.texture != nil ? "set" : "nil")")
                }
            }
        }
    }

    private func teardownSeamlessCursor(on display: CSDisplay?) {
        for o in cursorObservations { o.invalidate() }
        cursorObservations.removeAll()
        display?.cursor?.isInhibited = false
        metalView?.displayCursor = nil
        lastCursorSize = .zero
        lastCursorHotspot = .zero
    }

    private func seamlessLog(_ msg: String) {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("utm-cursor.log")
        let line = "\(Date()) \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private func applyGuestCursor(from cursor: CSCursor) {
        let size = cursor.cursorSize
        let hotspot = cursor.cursorHotspot
        seamlessLog("applyGuestCursor size=\(size) hotspot=\(hotspot) texture=\(cursor.texture != nil ? "set" : "nil")")
        guard size.width > 0, size.height > 0,
              let texture = cursor.texture else {
            DispatchQueue.main.async { [weak self] in
                self?.metalView?.displayCursor = nil
            }
            return
        }
        // Dedupe — KVO fires once per size + once per hotspot, but image
        // construction is cheap so it's fine if we run twice.
        lastCursorSize = size
        lastCursorHotspot = hotspot

        let w = Int(size.width)
        let h = Int(size.height)
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        // The texture is BGRA8 premultiplied. Read on the main thread —
        // SPICE channel callbacks fire on the main run loop in CocoaSpice
        // so by the time KVO has notified us, the texture is settled.
        pixels.withUnsafeMutableBytes { ptr in
            texture.getBytes(ptr.baseAddress!,
                             bytesPerRow: bytesPerRow,
                             from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                             size: MTLSize(width: w, height: h, depth: 1)),
                             mipmapLevel: 0)
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cgImage = CGImage(width: w, height: h,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 32,
                                    bytesPerRow: bytesPerRow,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: bitmapInfo,
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent) else { return }

        // NSCursor hotspot is in image-pixel coords; SPICE delivers in the
        // same. 1:1 image size — don't pre-scale for Retina (NSCursor
        // scales poorly; matches spice-gtk default).
        let image = NSImage(cgImage: cgImage, size: NSSize(width: w, height: h))
        let nsCursor = NSCursor(image: image, hotSpot: hotspot)

        DispatchQueue.main.async { [weak self] in
            self?.metalView?.displayCursor = nsCursor
        }
    }

    override func windowWillClose(_ notification: Notification) {
        vmDisplay?.removeRenderer(renderer!)
        stopAllCapture()
        if let screenChangedToken = screenChangedToken {
            NotificationCenter.default.removeObserver(screenChangedToken)
        }
        screenChangedToken = nil
        super.windowWillClose(notification)
    }
    
    override func enterLive() {
        metalView.isHidden = false
        screenshotView.isHidden = true
        if vmQemuConfig!.sharing.hasClipboardSharing {
            UTMPasteboard.general.requestPollingMode(forHashable: self) // start clipboard polling
        }
        // monitor Cmd+Q and Cmd+W and capture them if needed
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            if let self = self, !self.handleCaptureKeys(for: event) {
                return event
            } else {
                return nil
            }
        }
        // monitor caps lock
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            if let self = self {
                // sync caps lock while window is outside focus
                self.syncCapsLock(with: event.modifierFlags)
            }
        }
        // resize if we already have a vmDisplay
        if let vmDisplay = vmDisplay {
            displaySizeDidChange(size: vmDisplay.displaySize)
        }
        super.enterLive()
        setControl(.resize, isEnabled: false) // disable item
        if isWindowFocusAutoCapture {
            captureMouse()
        }
    }
    
    override func enterSuspended(isBusy busy: Bool) {
        if !busy {
            metalView.isHidden = true
            screenshotView.image = vm.screenshot?.image
            screenshotView.isHidden = false
        }
        if vm.state == .stopped {
            vmDisplay = nil
            vmInput = nil
            displaySize = .zero
        }
        stopAllCapture()
        super.enterSuspended(isBusy: busy)
    }

    private func stopAllCapture() {
        if vmQemuConfig!.sharing.hasClipboardSharing {
            UTMPasteboard.general.releasePollingMode(forHashable: self) // stop clipboard polling
        }
        if let localEventMonitor = self.localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor = globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        releaseMouse()
    }

    override func captureMouseButtonPressed(_ sender: Any) {
        captureMouse()
    }
}

// MARK: - SPICE IO
extension VMDisplayQemuMetalWindowController {
    override func spiceDidCreateInput(_ input: CSInput) {
        if vmInput == nil {
            vmInput = input
        }
        super.spiceDidCreateInput(input)
    }
    
    override func spiceDidDestroyInput(_ input: CSInput) {
        if vmInput == input {
            vmInput = nil
        }
        super.spiceDidDestroyInput(input)
    }
    
    override func spiceDidCreateDisplay(_ display: CSDisplay) {
        if !isSecondary && vmDisplay == nil && display.isPrimaryDisplay {
            vmDisplay = display
            displaySizeDidChange(size: display.displaySize)
        } else {
            super.spiceDidCreateDisplay(display)
        }
    }
    
    override func spiceDidDestroyDisplay(_ display: CSDisplay) {
        if vmDisplay == display {
            if isSecondary {
                DispatchQueue.main.async {
                    self.close()
                }
            } else {
                vmDisplay = nil
            }
        } else {
            super.spiceDidDestroyDisplay(display)
        }
    }
    
    override func spiceDidUpdateDisplay(_ display: CSDisplay) {
        if vmDisplay == display {
            if display.displaySize != self.displaySize {
                displaySizeDidChange(size: display.displaySize)
            }
        } else {
            super.spiceDidUpdateDisplay(display)
        }
    }
    
    override func spiceDynamicResolutionSupportDidChange(_ supported: Bool) {
        guard displayConfig!.isDynamicResolution else {
            super.spiceDynamicResolutionSupportDidChange(supported)
            return
        }
        if isDisplaySizeDynamic != supported {
            displaySizeDidChange(size: displaySize, shouldSaveResolution: false)
            DispatchQueue.main.async {
                if supported, let window = self.window {
                    self.restoreDynamicResolution(for: window)
                }
            }
        }
        isDisplaySizeDynamic = supported
        super.spiceDynamicResolutionSupportDidChange(supported)
    }
}
    
// MARK: - Screen management
extension VMDisplayQemuMetalWindowController {
    fileprivate func displaySizeDidChange(size: CGSize, shouldSaveResolution: Bool = true) {
        // cancel any pending resize
        cancelResize?.cancel()
        cancelResize = nil
        guard size != .zero else {
            logger.debug("Ignoring zero size display")
            return
        }
        DispatchQueue.main.async {
            logger.debug("resizing to: (\(size.width), \(size.height))")
            guard let window = self.window else {
                logger.debug("Invalid window, ignoring size change")
                return
            }
            self.displaySize = size
            if self.isFullScreen {
                _ = self.updateHostScaling(for: window, frameSize: window.frame.size)
            } else {
                self.updateHostFrame(forGuestResolution: size)
            }
            if shouldSaveResolution {
                self.saveDynamicResolution()
            }
        }
    }
    
    func windowDidChangeScreen(_ notification: Notification) {
        logger.debug("screen changed")
        if let vmDisplay = self.vmDisplay {
            displaySizeDidChange(size: vmDisplay.displaySize)
        }
    }

    private func contentMinSize(in window: NSWindow, for displaySize: CGSize) -> CGSize {
        let currentScreenScale = window.screen?.backingScaleFactor ?? 1.0
        let nativeScale = displayConfig!.isNativeResolution ? 1.0 : currentScreenScale
        let minScaledSize = CGSize(width: displaySize.width * nativeScale / currentScreenScale, height: displaySize.height * nativeScale / currentScreenScale)
        // In fullscreen, use the full screen frame (including the notch wings)
        // rather than visibleFrame, which excludes the menu-bar/notch region.
        // Pairs with NSPrefersDisplaySafeAreaCompatibilityMode=false in Info.plist.
        let availableFrame = isFullScreen ? window.screen?.frame : window.screen?.visibleFrame
        guard let screenSize = availableFrame?.size else {
            return minScaledSize
        }
        let excessSize = window.frameRect(forContentRect: .zero).size
        // if the window is larger than our host screen, shrink the min size allowed
        let widthScale = (screenSize.width - excessSize.width) / displaySize.width
        let heightScale = (screenSize.height - excessSize.height) / displaySize.height
        let scale = min(min(widthScale, heightScale), 1.0)
        return CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
    }

    fileprivate func updateHostFrame(forGuestResolution size: CGSize) {
        guard let window = window else { return }
        guard let vmDisplay = vmDisplay else { return }
        let currentScreenScale = window.screen?.backingScaleFactor ?? 1.0
        let nativeScale = displayConfig!.isNativeResolution ? 1.0 : currentScreenScale
        // change optional scale if needed
        if isDisplaySizeDynamic || (!displayConfig!.isNativeResolution && renderer.viewportScale < currentScreenScale) {
            renderer.viewportScale = nativeScale
        }
        let fullContentWidth = size.width * renderer.viewportScale / currentScreenScale
        let fullContentHeight = size.height * renderer.viewportScale / currentScreenScale
        let contentRect = CGRect(x: window.frame.origin.x,
                                 y: 0,
                                 width: ceil(fullContentWidth),
                                 height: ceil(fullContentHeight))
        var windowRect = window.frameRect(forContentRect: contentRect)
        windowRect.origin.y = window.frame.origin.y + window.frame.height - windowRect.height
        if isDisplaySizeDynamic {
            window.contentMinSize = minDynamicSize
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
            window.setFrame(windowRect, display: false, animate: false)
        } else {
            window.contentMinSize = contentMinSize(in: window, for: size)
            window.contentAspectRatio = size
            window.setFrame(windowRect, display: false, animate: true)
        }
    }
    
    fileprivate func updateHostScaling(for window: NSWindow, frameSize: NSSize) -> NSSize {
        guard displaySize != .zero else { return frameSize }
        guard let vmDisplay = self.vmDisplay else { return frameSize }
        let currentScreenScale = window.screen?.backingScaleFactor ?? 1.0
        // In fullscreen, use the raw frame size — `contentRect(forFrameRect:)`
        // still subtracts toolbar height even when the toolbar is auto-hidden,
        // which letterboxes the framebuffer (LR black bars from height-fit
        // scaling). Outside fullscreen the toolbar is genuinely visible and
        // contentRect is the right answer.
        let targetContentSize = isFullScreen ? frameSize : window.contentRect(forFrameRect: CGRect(origin: .zero, size: frameSize)).size
        let targetScaleX = targetContentSize.width * currentScreenScale / displaySize.width
        let targetScaleY = targetContentSize.height * currentScreenScale / displaySize.height
        let targetScale = min(targetScaleX, targetScaleY)
        let scaledSize = CGSize(width: displaySize.width * targetScale / currentScreenScale, height: displaySize.height * targetScale / currentScreenScale)
        let targetFrameSize = window.frameRect(forContentRect: CGRect(origin: .zero, size: scaledSize)).size
        renderer.viewportScale = targetScale
        logger.debug("changed scale \(targetScale)")
        return targetFrameSize
    }
    
    fileprivate func updateGuestResolution(for window: NSWindow, frameSize: NSSize) -> NSSize {
        guard let vmDisplay = self.vmDisplay else { return frameSize }
        let currentScreenScale = window.screen?.backingScaleFactor ?? 1.0
        let nativeScale = displayConfig!.isNativeResolution ? currentScreenScale : 1.0
        let targetSize = window.contentRect(forFrameRect: CGRect(origin: .zero, size: frameSize)).size
        let targetSizeScaled = displayConfig!.isNativeResolution ? targetSize.applying(CGAffineTransform(scaleX: nativeScale, y: nativeScale)) : targetSize
        logger.debug("Requesting resolution: (\(targetSizeScaled.width), \(targetSizeScaled.height))")
        let bounds = CGRect(origin: .zero, size: targetSizeScaled)
        vmDisplay.requestResolution(bounds)
        return frameSize
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !self.isDisplaySizeDynamic else {
            return frameSize
        }
        let newSize = updateHostScaling(for: sender, frameSize: frameSize)
        if isFullScreen {
            return frameSize
        } else {
            return newSize
        }
    }
    
    func windowDidResize(_ notification: Notification) {
        guard self.isDisplaySizeDynamic, let window = self.window else {
            return
        }
        debounceResize?.cancel()
        debounceResize = DispatchWorkItem {
            self._handleResizeEnd(for: window)
        }
        // when resizing with a mouse drag, we get flooded with this notification
        // when using accessibility APIs, we do not get a `windowDidEndLiveResize` notification
        DispatchQueue.main.asyncAfter(deadline: .now() + resizeDebounceSecs, execute: debounceResize!)
    }
    
    func windowDidEndLiveResize(_ notification: Notification) {
        guard self.isDisplaySizeDynamic, let window = self.window else {
            return
        }
        _handleResizeEnd(for: window)
    }
    
    private func _handleResizeEnd(for window: NSWindow) {
        debounceResize?.cancel()
        debounceResize = nil
        _ = updateGuestResolution(for: window, frameSize: window.frame.size)
        cancelResize?.cancel()
        cancelResize = DispatchWorkItem {
            if let vmDisplay = self.vmDisplay {
                self.displaySizeDidChange(size: vmDisplay.displaySize)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + resizeTimeoutSecs, execute: cancelResize!)
    }
    
    func windowDidEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        // WingsAwareWindow.enterFakeFullScreen has already cleared
        // contentAspectRatio/contentMinSize and resized the window to
        // screen.frame. Re-run scaling now that isFullScreen is true so
        // updateHostScaling uses the new (frame-not-contentRect) branch.
        if let window = self.window, displaySize != .zero {
            _ = updateHostScaling(for: window, frameSize: window.frame.size)
        }
        if isFullScreenAutoCapture {
            captureMouse()
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        // Repopulate contentMinSize/contentAspectRatio from the guest's
        // current resolution; WingsAwareWindow restored the pre-fullscreen
        // values which may be stale if the guest resized during fullscreen.
        if let vmDisplay = self.vmDisplay {
            displaySizeDidChange(size: vmDisplay.displaySize, shouldSaveResolution: false)
        }
        if isFullScreenAutoCapture {
            releaseMouse()
        }
    }
    
    func windowDidBecomeMain(_ notification: Notification) {
        // Do not capture mouse if user did not clicked inside the metalView because the window will be draged if user hold the mouse button.
        guard let window = window,
              window.mouseLocationOutsideOfEventStream.y < metalView.frame.height,
              (captureMouseToolbarButton?.state ?? .off) == .off,
              isWindowFocusAutoCapture else {
            return
        }
        captureMouse()
    }
    
    func windowDidResignMain(_ notification: Notification) {
        releaseMouse()
    }
    
    override func windowDidBecomeKey(_ notification: Notification) {
        if isFullScreen && isFullScreenAutoCapture {
            captureMouse()
        }
        super.windowDidBecomeKey(notification)
    }
    
    override func windowDidResignKey(_ notification: Notification) {
        releaseMouse()
        super.windowDidResignKey(notification)
    }
}

// MARK: - Save and restore resolution
@MainActor extension VMDisplayQemuMetalWindowController {
    func saveDynamicResolution() {
        guard isDisplaySizeDynamic else {
            return
        }
        var resolution = UTMRegistryEntry.Resolution()
        resolution.isFullscreen = isFullScreen
        resolution.size = displaySize
        vm.registryEntry.resolutionSettings[id] = resolution
    }

    func restoreDynamicResolution(for window: NSWindow) {
        guard let resolution = vm.registryEntry.resolutionSettings[id] else {
            return
        }
        if resolution.isFullscreen && !isFullScreen {
            window.toggleFullScreen(self)
        } else if let vmDisplay = vmDisplay, resolution.size != .zero {
            vmDisplay.requestResolution(CGRect(origin: .zero, size: resolution.size))
        } else {
            _ = self.updateGuestResolution(for: window, frameSize: window.frame.size)
        }
    }
}

// MARK: - Input events
extension VMDisplayQemuMetalWindowController: VMMetalViewInputDelegate {
    var shouldUseCmdOptForCapture: Bool {
        isAlternativeCaptureKey || NSWorkspace.shared.isVoiceOverEnabled
    }

    func captureMouse() {
        guard NSApp.modalWindow == nil && window?.attachedSheet == nil else {
            return // don't capture if modal is shown
        }
        let action = { () -> Void in
            self.qemuVM.requestInputTablet(false)
            self.metalView?.captureMouse()
            
            self.captureMouseToolbarButton?.state = .on
            
            let format = NSLocalizedString("Press %@ to release cursor", comment: "VMDisplayQemuMetalWindowController")
            let keys = NSLocalizedString(self.shouldUseCmdOptForCapture ? "⌘+⌥" : "⌃+⌥", comment: "VMDisplayQemuMetalWindowController")
            self.window?.subtitle = String.localizedStringWithFormat(format, keys)
            
            self.window?.makeFirstResponder(self.metalView)
            self.syncCapsLock()
        }
        if !isCursorCaptureAlertShown || (isFullScreen && !isFullscreenCursorCaptureAlertShown) {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Captured mouse", comment: "VMDisplayQemuMetalWindowController")
            
            let format = NSLocalizedString("To release the mouse cursor, press %@ at the same time.", comment: "VMDisplayQemuMetalWindowController")
            let keys = NSLocalizedString(self.shouldUseCmdOptForCapture ? "⌘+⌥ (Cmd+Opt)" : "⌃+⌥ (Ctrl+Opt)", comment: "VMDisplayQemuMetalWindowController")
            alert.informativeText = String.localizedStringWithFormat(format, keys)
            
            alert.showsSuppressionButton = true
            alert.beginSheetModal(for: window!) { _ in
                if alert.suppressionButton?.state ?? .off == .on {
                    self.isCursorCaptureAlertShown = true
                    if self.isFullScreen {
                        self.isFullscreenCursorCaptureAlertShown = true
                    }
                }
                DispatchQueue.main.async(execute: action)
            }
        } else {
            action()
        }
    }
    
    func releaseMouse() {
        syncCapsLock()
        qemuVM.requestInputTablet(true)
        metalView?.releaseMouse()
        self.captureMouseToolbarButton?.state = .off
        self.window?.subtitle = defaultSubtitle
    }
    
    func mouseMove(absolutePoint: CGPoint, buttonMask: CSInputButton) {
        guard let window = self.window else { return }
        guard let vmInput = vmInput, !vmInput.serverModeCursor else {
            logger.trace("requesting client mode cursor")
            qemuVM.requestInputTablet(true)
            return
        }
        let currentScreenScale = window.screen?.backingScaleFactor ?? 1.0
        let viewportScale = renderer?.viewportScale ?? 1.0
        let frameSize = metalView.frame.size
        let newX = absolutePoint.x * currentScreenScale / viewportScale
        let newY = (frameSize.height - absolutePoint.y) * currentScreenScale / viewportScale
        let point = CGPoint(x: newX, y: newY)
        logger.trace("move cursor: cocoa (\(absolutePoint.x), \(absolutePoint.y)), native (\(newX), \(newY))")
        vmInput.sendMousePosition(buttonMask, absolutePoint: point, forMonitorID: vmDisplay?.monitorID ?? 0)
        vmDisplay?.cursor?.move(to: point) // required to show cursor on screen
    }
    
    func mouseMove(relativePoint: CGPoint, buttonMask: CSInputButton) {
        guard let vmInput = vmInput, vmInput.serverModeCursor else {
            logger.trace("requesting server mode cursor")
            qemuVM.requestInputTablet(false)
            return
        }
        let translated = CGPoint(x: relativePoint.x, y: -relativePoint.y)
        vmInput.sendMouseMotion(buttonMask, relativePoint: translated, forMonitorID: vmDisplay?.monitorID ?? 0)
    }
    
    private func modifyMouseButton(_ button: CSInputButton) -> CSInputButton {
        let buttonMod: CSInputButton
        if button.contains(.left) && ctrlKeyDown && isCtrlRightClick {
            buttonMod = button.subtracting(.left).union(.right)
        } else {
            buttonMod = button
        }
        return buttonMod
    }
    
    func mouseDown(button: CSInputButton, mask: CSInputButton) {
        vmInput?.sendMouseButton(modifyMouseButton(button), mask: modifyMouseButton(mask), pressed: true)
    }
    
    func mouseUp(button: CSInputButton, mask: CSInputButton) {
        vmInput?.sendMouseButton(modifyMouseButton(button), mask: modifyMouseButton(mask), pressed: false)
    }
    
    func mouseScroll(dy: CGFloat, buttonMask: CSInputButton) {
        let scrollDy = isInvertScroll ? -dy : dy
        vmInput?.sendMouseScroll(.smooth, buttonMask: buttonMask, dy: scrollDy)
    }
    
    private func sendExtendedKey(_ button: CSInputKey, keyCode: Int) {
        if (keyCode & 0xFF00) == 0xE000 {
            vmInput?.send(button, code: Int32(0x100 | (keyCode & 0xFF)))
        } else if keyCode >= 0x100 {
            logger.warning("ignored invalid keycode \(keyCode)");
        } else {
            vmInput?.send(button, code: Int32(keyCode))
        }
    }
    
    func keyDown(scanCode: Int) {
        if (scanCode & 0xFF) == 0x1D { // Ctrl
            ctrlKeyDown = true
        }
        if !isCapsLockKey && (scanCode & 0xFF) == 0x3A { // Caps Lock
            return
        }
        sendExtendedKey(.press, keyCode: scanCode)
    }
    
    func keyUp(scanCode: Int) {
        if (scanCode & 0xFF) == 0x1D { // Ctrl
            ctrlKeyDown = false
        }
        if !isCapsLockKey && (scanCode & 0xFF) == 0x3A { // Caps Lock
            return
        }
        sendExtendedKey(.release, keyCode: scanCode)
    }
    
    private func handleCaptureKeys(for event: NSEvent) -> Bool {
        // if captured we route all keyevents to view
        if let metalView = metalView, metalView.isMouseCaptured {
            if event.type == .keyDown {
                metalView.keyDown(with: event)
            } else if event.type == .keyUp {
                metalView.keyUp(with: event)
            }
            return true
        }
        
        if event.modifierFlags.contains(.command) && event.type == .keyUp {
            // for some reason, macOS doesn't like to send Cmd+KeyUp
            metalView.keyUp(with: event)
            return false
        }
        if event.type == .keyDown && (event.keyCode == kVK_JIS_Eisu || event.keyCode == kVK_JIS_Kana) {
            // Eisu and Kana keydown events are swallowed and sent directly to IME
            metalView.keyDown(with: event)
            return true
        }
        return false
    }
    
    /// Syncs the host caps lock state with the guest
    /// - Parameter modifier: An NSEvent modifier, or nil to get the current system state
    func syncCapsLock(with modifier: NSEvent.ModifierFlags? = nil) {
        guard !isCapsLockKey else {
            // ignore sync if user disabled it
            return
        }
        guard let vmInput = vmInput else {
            return
        }
        let capsLock: Bool
        if let modifier = modifier {
            capsLock = modifier.contains(.capsLock)
        } else {
            let status = CGEventSource.flagsState(.hidSystemState)
            capsLock = status.contains(.maskAlphaShift)
        }
        var locks = vmInput.keyLock
        if capsLock {
            locks.update(with: .caps)
        } else {
            locks.subtract(.caps)
        }
        vmInput.keyLock = locks
    }
    
    /// Update virtual num lock status if we force num pad to on
    func didUseNumericPad() {
        guard isNumLockForced else {
            return // nothing to do
        }
        guard let vmInput = vmInput else {
            return
        }
        if !vmInput.keyLock.contains(.num) {
            vmInput.keyLock.insert(.num)
        }
    }
}

// MARK: - Keyboard shortcuts menu
extension VMDisplayQemuMetalWindowController {
    override func updateKeyboardShortcutMenu(_ menu: NSMenu) {
        let keyboardShortcuts = UTMKeyboardShortcuts.shared.loadKeyboardShortcuts()
        for (index, keyboardShortcut) in keyboardShortcuts.enumerated() {
            let item = NSMenuItem()
            item.title = keyboardShortcut.title
            item.target = self
            item.action = #selector(keyboardShortcutHandler)
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let item = NSMenuItem()
        item.title = NSLocalizedString("Edit…", comment: "VMDisplayQemuMetalWindowController")
        item.target = self
        item.action = #selector(keyboardShortcutEdit)
        menu.addItem(item)
    }
    
    @MainActor @objc private func keyboardShortcutHandler(sender: AnyObject) {
        let keyboardShortcuts = UTMKeyboardShortcuts.shared.loadKeyboardShortcuts()
        let item = sender as! NSMenuItem
        let index = item.tag
        guard index < keyboardShortcuts.count else {
            return
        }
        let keys = keyboardShortcuts[index]
        withErrorAlert {
            try await self.qemuVM.monitor?.sendKeys(keys)
        }
    }
    
    @MainActor @objc private func keyboardShortcutEdit(sender: AnyObject) {
        guard let window = window else {
            return
        }
        let content = NSHostingController(rootView: VMKeyboardShortcutsView {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }.padding())
        var fittingSize = content.view.fittingSize
        fittingSize.width = 400
        let sheetWindow = NSWindow(contentViewController: content)
        sheetWindow.setContentSize(fittingSize)
        window.beginSheet(sheetWindow)
    }
}

// Custom NSWindow class declared as customClass on VMDisplayWindow.xib.
//
// Native AppKit fullscreen hosts the window's contentView in a managed
// compositing container that's sized to visibleFrame regardless of
// window.frame, with no public API to override. On a 16" MBP that means
// the menu-bar/notch-wings region (~33pt at the top) is permanently
// unreachable from the guest framebuffer.
//
// Instead of relying on native fullscreen, override toggleFullScreen to
// implement "fake fullscreen": .borderless styleMask, frame = screen.frame,
// auto-hide menu bar + dock. We fire windowDidEnter/ExitFullScreen on the
// delegate manually so the controller's fullscreen lifecycle (isFullScreen
// flag, mouse capture, scaling re-calc) runs unchanged.
@objc(WingsAwareWindow)
class WingsAwareWindow: NSWindow {
    private var savedFrame: NSRect = .zero
    private var savedStyleMask: NSWindow.StyleMask = []
    private var savedPresentationOptions: NSApplication.PresentationOptions = []
    private var savedContentAspectRatio: NSSize = .zero
    private var savedContentMinSize: NSSize = .zero
    private var savedBackgroundColor: NSColor?
    private var savedHasShadow: Bool = true
    private var cursorConfinementMonitor: Any?
    private(set) var isFakeFullScreen: Bool = false

    // Borderless windows can't accept key/main without these overrides.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func toggleFullScreen(_ sender: Any?) {
        if isFakeFullScreen {
            exitFakeFullScreen()
        } else {
            enterFakeFullScreen()
        }
    }

    private func enterFakeFullScreen() {
        guard let screen = self.screen else { return }
        savedFrame = self.frame
        savedStyleMask = self.styleMask
        savedPresentationOptions = NSApp.presentationOptions
        savedContentAspectRatio = self.contentAspectRatio
        savedContentMinSize = self.contentMinSize
        savedBackgroundColor = self.backgroundColor
        savedHasShadow = self.hasShadow

        // updateHostFrame leaves contentAspectRatio/contentMinSize set to
        // the guest's resolution; setFrame(screen.frame) on a constrained
        // window asserts in _adjustNeedsDisplayRegionForNewFrame.
        self.contentAspectRatio = .zero
        self.contentMinSize = .zero

        self.styleMask = [.borderless, .resizable]
        // Black backing so any subpixel-alignment gap doesn't expose the
        // default light-grey window backing.
        self.backgroundColor = .black
        // The window shadow's inner edge bleeds 1-2px onto screen pixels
        // when the frame == screen.frame; visible as a grey halo.
        self.hasShadow = false
        // .hideMenuBar / .hideDock keep them fully hidden — no reveal
        // when the cursor hits the top/bottom edge. .autoHide* would
        // pop them out and break the wings-edge-to-edge illusion when
        // the user nudges the cursor against an edge. Allowed here
        // because our window isn't in native .fullScreen styleMask
        // (which would forbid .hideDock); we use borderless instead.
        NSApp.presentationOptions = [.hideMenuBar, .hideDock]
        super.setFrame(screen.frame, display: true)
        self.makeKeyAndOrderFront(nil)
        isFakeFullScreen = true

        // Clamp the cursor to the window's frame whenever it tries to
        // move outside. macOS's natural clamp at screen edges sometimes
        // lets the cursor slip onto Control Center reveal triggers and
        // hot-corner regions even with .hideMenuBar/.hideDock set —
        // this monitor catches the cursor mid-event and warps it back.
        cursorConfinementMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            guard let self = self, self.isFakeFullScreen else { return event }
            let loc = NSEvent.mouseLocation  // Cocoa coords (Y up)
            let f = self.frame
            let inset: CGFloat = 1
            let clampedX = min(max(loc.x, f.minX + inset), f.maxX - inset)
            let clampedY = min(max(loc.y, f.minY + inset), f.maxY - inset)
            if clampedX != loc.x || clampedY != loc.y, let s = self.screen {
                // CGWarp uses CG coords (Y down, origin at top-left).
                let cgY = s.frame.maxY - clampedY
                CGWarpMouseCursorPosition(CGPoint(x: clampedX, y: cgY))
            }
            return event
        }

        let n = Notification(name: NSWindow.didEnterFullScreenNotification, object: self)
        (delegate as? NSWindowDelegate)?.windowDidEnterFullScreen?(n)
    }

    private func exitFakeFullScreen() {
        let n = Notification(name: NSWindow.didExitFullScreenNotification, object: self)
        (delegate as? NSWindowDelegate)?.windowDidExitFullScreen?(n)

        if let mon = cursorConfinementMonitor {
            NSEvent.removeMonitor(mon)
            cursorConfinementMonitor = nil
        }

        NSApp.presentationOptions = savedPresentationOptions
        self.styleMask = savedStyleMask
        self.backgroundColor = savedBackgroundColor
        self.hasShadow = savedHasShadow
        super.setFrame(savedFrame, display: true)
        self.contentAspectRatio = savedContentAspectRatio
        self.contentMinSize = savedContentMinSize
        isFakeFullScreen = false
    }

    // Force any setFrame call while in fake-fullscreen to stay at
    // screen.frame so external resizes don't shrink us.
    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        var rect = frameRect
        if isFakeFullScreen, let screen = self.screen {
            rect = screen.frame
        }
        super.setFrame(rect, display: flag, animate: animateFlag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if isFakeFullScreen, let screen = self.screen {
            rect = screen.frame
        }
        super.setFrame(rect, display: flag)
    }
}
