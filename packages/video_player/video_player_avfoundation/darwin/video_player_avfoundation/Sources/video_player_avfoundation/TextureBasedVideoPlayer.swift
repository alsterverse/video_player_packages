// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#else
  #error("Unsupported platform.")
#endif

#if canImport(video_player_avfoundation_objc)
  import video_player_avfoundation_objc
#endif

/// How long expectFrame keeps the display link running for a frame that doesn't arrive.
private let maximumFrameWait: TimeInterval = 0.2
/// How long to keep the display link running for the first frame after loadAsset, which takes
/// longer to produce one than a seek does.
private let maximumAssetLoadWait: TimeInterval = 1.0
/// How long to wait for the decoder before reporting readiness anyway.
///
/// Readiness gated on a frame that never arrives would leave the page on its thumbnail forever,
/// which is worse than the flash the gating fixes.
private let maximumFirstFrameWait: TimeInterval = 1.0

/// A subclass of VideoPlayer that adds functionality related to texture-based view as a way of
/// displaying the video in the app. It manages the CALayer associated with the Flutter view,
/// updates frames, and handles display link callbacks.
/// If you need to display a video using platform view, use VideoPlayer instead.
class TextureBasedVideoPlayer: VideoPlayer, FlutterTexture, AVPlayerItemOutputPullDelegate {

  // The updater that drives callbacks to the engine to indicate that a new frame is ready.
  private let frameUpdater: FVPFrameUpdater
  // The display link that drives frameUpdater.
  private var displayLink: FVPDisplayLink?
  // The latest buffer obtained from video output. This is stored so that it can be returned from
  // copyPixelBuffer again if nothing new is available, since the engine has undefined behavior when
  // returning NULL.
  //
  // copyPixelBuffer reads and writes it on the raster thread, and the placeholder that loadAsset
  // installs replaces it from the main thread, so every access goes through latestPixelBufferLock.
  private var latestPixelBuffer: CVPixelBuffer?
  private let latestPixelBufferLock = NSLock()
  // The time that represents when the next frame displays.
  private var targetTime: CFTimeInterval = 0
  // Whether to enqueue textureFrameAvailable from copyPixelBuffer.
  private var selfRefresh = true
  // The time that represents the start of average frame duration measurement.
  private var startTime: CFTimeInterval = 0
  // The number of frames since the start of average frame duration measurement.
  private var framesCount: Int = 0
  // The latest frame duration since there was significant change.
  private var latestDuration: CFTimeInterval = 0
  // Whether a new frame needs to be provided to the engine regardless of the current play/pause state
  // (e.g., after a seek while paused). If true, the display link should continue to run until the next
  // frame is successfully provided.
  private var waitingForFrame = false
  // Incremented by each expectFrame, so that the timeout of an earlier expectation is ignored.
  private var frameExpectationGeneration = 0
  // Whether the decoder has signalled that it has a frame for the current item. Readiness is
  // withheld from Dart until it has: the item reaching readyToPlay says the item can play, not that
  // there is a picture, and the page puts the texture on screen the moment Dart is told.
  private var hasDecodableFrame = false
  // Whether the engine has been handed a decoded frame of the current asset.
  private var hasRenderedFirstFrame = false
  // Readiness reports that arrived before the decoder had a frame, to be sent once it does (or once
  // the wait times out).
  private var initializedPending = false
  private var reloadingEndPending = false
  // Invalidates the timeout of a previous first-frame wait when a new one starts.
  private var firstFrameWaitGeneration = 0
  // Diagnostic: wall clock, in milliseconds, of the most recent load. Zero once the first real frame
  // of that asset has been served.
  private var diagLoadTime: Double = 0
  // Diagnostic: how many times the placeholder has been handed to the engine since that load. Each
  // one is a frame of placeholder on screen if the widget has already swapped away from its
  // thumbnail.
  private var diagPlaceholderServed = 0
  // Diagnostic: when the artificial hold on the current content expires.
  private var diagHoldUntil: Double = 0
  // Diagnostic: consecutive copyPixelBuffer calls while paused. The selfRefresh loop has no exit
  // when paused with no incoming buffers, so a large count means the display link is stuck on and
  // the raster thread is churning.
  private var pausedRefreshCount = 0

  /// The AVPlayerLayer used to display the video content.
  /// This is to fix 2 bugs: 1. blank video for encrypted video streams on iOS 16
  /// (https://github.com/flutter/flutter/issues/111457) and 2. swapped width and height for some
  /// video streams (not just iOS 16).  (https://github.com/flutter/flutter/issues/109116). An
  /// invisible AVPlayerLayer is used to overwrite the protection of pixel buffers in those streams
  /// for issue #1, and restore the correct width and height for issue #2.
  private(set) var playerLayer: AVPlayerLayer?

  /// Initializes a new instance of TextureBasedVideoPlayer with the given player item,
  /// frame updater, display link, AV factory, and view provider.
  init(
    playerItem: WrappedAVPlayerItem,
    frameUpdater: FVPFrameUpdater,
    displayLink: FVPDisplayLink,
    avFactory: WrappedAVObjectFactory,
    viewProvider: FVPViewProvider
  ) {
    self.frameUpdater = frameUpdater
    self.displayLink = displayLink
    self.frameUpdater.displayLink = displayLink

    // Configure output. AVVideoColorPropertiesKey must be declared on the output settings (not on
    // pixel buffer attributes, where AVFoundation silently ignores it) so that HDR sources are
    // tone-mapped to BT.709 SDR for the Flutter texture. Platform view players need no output, and
    // keep their HDR: AVPlayerLayer renders it directly into an EDR-enabled layer.
    // See https://github.com/flutter/flutter/issues/91241
    let outputSettings: [String: Any] = [
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
      kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA),
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    super.init(
      playerItem: playerItem, avFactory: avFactory, viewProvider: viewProvider,
      pixelBufferSource: avFactory.videoOutput(outputSettings: outputSettings))

    // A player created for a page not shown before never goes through loadAsset, so the diagnostic
    // episode starts here too; otherwise the first view of a video would go unmeasured.
    diagLoadTime = wallClockMillis()

    // This is to fix 2 bugs: 1. blank video for encrypted video streams on iOS 16
    // (https://github.com/flutter/flutter/issues/111457) and 2. swapped width and height for some
    // video streams (not just iOS 16).  (https://github.com/flutter/flutter/issues/109116). An
    // invisible AVPlayerLayer is used to overwrite the protection of pixel buffers in those streams
    // for issue #1, and restore the correct width and height for issue #2.
    let layer = AVPlayerLayer(player: player)
    #if os(iOS)
      let flutterLayer = viewProvider.viewController?.view.layer
    #else
      let flutterLayer = viewProvider.view?.layer
    #endif
    playerLayer = layer
    flutterLayer?.addSublayer(layer)
  }

  /// Sets the texture Identifier for the frame updater. This method should be called once the texture
  /// identifier is obtained from the texture registry.
  func setTextureIdentifier(_ textureIdentifier: Int64) {
    frameUpdater.textureIdentifier = textureIdentifier

    // Ensure that the first frame is drawn once available, even if the video isn't played, since
    // the engine is now expecting the texture to be populated.
    expectFrame()
  }

  /// Ensures that the frame updater runs until a frame is rendered, regardless of play/pause state,
  /// or until the timeout passes.
  private func expectFrame(timeout: TimeInterval = maximumFrameWait) {
    waitingForFrame = true
    displayLink?.running = true

    frameExpectationGeneration += 1
    let generation = frameExpectationGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
      MainActor.assumeIsolated {
        guard let self = self, self.frameExpectationGeneration == generation else { return }
        // Clear the expectation when it expires even if playing right now: left set, a later pause
        // keeps the display link running (updatePlayingState ORs it in), and a paused player never
        // produces the buffer that would clear it, leaving the selfRefresh loop redrawing every vsync.
        self.waitingForFrame = false
        if !self.isPlaying {
          self.displayLink?.running = false
        }
      }
    }
  }

  // MARK: Overrides

  override var shouldApplyVideoCompositionForTransform: Bool { true }

  @MainActor override func updatePlayingState() {
    super.updatePlayingState()
    // If the texture is still waiting for an expected frame, the display link needs to keep
    // running until it arrives regardless of the play/pause state.
    displayLink?.running = isPlaying || waitingForFrame
  }

  @MainActor override func configureForReadyToPlay(item: AVPlayerItem) {
    super.configureForReadyToPlay(item: item)
    awaitFirstDecodableFrame()

    // Read the content frame rate asynchronously: querying nominalFrameRate synchronously blocks the
    // main thread while AVFoundation loads it, which for HTTP(S) assets is a network-bound stall.
    // Until it loads, the display link keeps firing every vsync.
    guard
      let videoTrack = item.tracks.lazy.compactMap(\.assetTrack).first(where: {
        $0.mediaType == .video
      })
    else { return }
    Task { [weak self] in
      let nominalFrameRate = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
      self?.applyContentFrameRate(nominalFrameRate)
    }
  }

  @MainActor override func reportInitialized() async {
    if hasDecodableFrame || !FVPFirstFrameGatingEnabled() {
      await super.reportInitialized()
      return
    }
    diagLog("ev=ready.deferred tex=\(frameUpdater.textureIdentifier) kind=initialized")
    initializedPending = true
  }

  @MainActor override func finishLoadingNewAsset() async {
    if hasDecodableFrame || !FVPFirstFrameGatingEnabled() {
      await super.finishLoadingNewAsset()
      return
    }
    diagLog("ev=ready.deferred tex=\(frameUpdater.textureIdentifier) kind=reloading")
    reloadingEndPending = true
  }

  @MainActor override func loadAsset(url: URL, httpHeaders: [String: String]) {
    diagLoadTime = wallClockMillis()
    diagPlaceholderServed = 0
    diagLog("ev=load.begin tex=\(frameUpdater.textureIdentifier) url=\(url.lastPathComponent)")

    // The frame the previous asset decoded says nothing about this one.
    hasDecodableFrame = false
    hasRenderedFirstFrame = false
    diagHoldUntil = 0

    // Abandon the previous asset's first-frame wait along with the asset. Superseding a load in
    // flight would otherwise leave its timeout armed against this asset, releasing a readiness the
    // new item hasn't reached. The new item defers its own once it is ready to play.
    firstFrameWaitGeneration += 1
    reloadingEndPending = false

    // Stop the previous video's last frame from showing during the load.
    let placeholder = makeTransparentPixelBuffer()
    replaceLatestPixelBuffer(placeholder)
    if placeholder != nil {
      diagLog("ev=placeholder.set tex=\(frameUpdater.textureIdentifier) color=transparent")
    }

    // Reset timing state to avoid drift issues with the new video.
    targetTime = 0

    super.loadAsset(url: url, httpHeaders: httpHeaders)

    expectFrame(timeout: maximumAssetLoadWait)
  }

  @MainActor override func stop() {
    super.stop()

    // Stopping drops the item, so held-back readiness has nothing left to report on. Players are
    // often stopped inside the first-frame wait, and a timeout left armed would report an item
    // that is gone.
    abandonFirstFrameWait()

    // The base implementation never recomputes the display link, so a player that was playing would
    // keep it running after being stopped. A later loadAsset re-arms it.
    waitingForFrame = false
    displayLink?.running = false
  }

  @MainActor override func seek(to position: Int64) async throws {
    // Reading player.currentTime() to skip a redundant expectFrame, as upstream does, takes the
    // item's lock, which is held for hundreds of milliseconds while a freshly swapped-in item is
    // prepared, freezing the main thread. Always expecting the frame is harmless by comparison.
    try await super.seek(to: position)
    // Ensure that a frame is drawn once available, even if currently paused. This must use the
    // display link rather than just informing the engine that a new frame is available because the
    // seek completing doesn't guarantee that the pixel buffer is already available.
    expectFrame()
  }

  @MainActor override func dispose() {
    super.dispose()
    abandonFirstFrameWait()

    playerLayer?.removeFromSuperlayer()

    displayLink?.running = false
    displayLink = nil
  }

  // MARK: First frame gating

  /// Asks the output to report when it can produce a frame, and starts the wait.
  ///
  /// This is the only available signal that doesn't depend on the engine: the engine calls
  /// copyPixelBuffer only for a texture that is already on screen, and the texture only goes on
  /// screen once Dart is told the player is ready, so gating readiness on a frame actually handed
  /// over would deadlock.
  private func awaitFirstDecodableFrame() {
    guard let videoOutput = pixelBufferSource?.videoOutput else { return }
    hasDecodableFrame = false
    firstFrameWaitGeneration += 1
    let generation = firstFrameWaitGeneration

    videoOutput.setDelegate(self, queue: .main)
    videoOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: 0)

    DispatchQueue.main.asyncAfter(deadline: .now() + maximumFirstFrameWait) { [weak self] in
      MainActor.assumeIsolated {
        guard let self = self, self.firstFrameWaitGeneration == generation,
          !self.hasDecodableFrame
        else { return }
        diagLog("ev=frame.decodable.timeout tex=\(self.frameUpdater.textureIdentifier)")
        self.releaseDeferredReadiness()
      }
    }
  }

  nonisolated func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
    // The delegate queue is main; see awaitFirstDecodableFrame.
    MainActor.assumeIsolated {
      if hasDecodableFrame { return }
      diagLog(
        "ev=frame.decodable tex=\(frameUpdater.textureIdentifier) "
          + "sinceLoadMs=\(diagLoadTime > 0 ? wallClockMillis() - diagLoadTime : -1)")
      releaseDeferredReadiness()
    }
  }

  /// Sends whatever readiness was held back, and makes sure the display link is running so the
  /// frame reaches the engine as soon as the texture is on screen.
  private func releaseDeferredReadiness() {
    // Both releases assert that the current item is ready to play, but the triggers are not tied to
    // one: a media-data callback queued for an item loadAsset has since swapped out still lands
    // here, and the new item may not be ready yet. Leave the readiness held; the current item
    // releases it once it has a frame of its own.
    guard player.currentItem?.status == .readyToPlay else {
      diagLog("ev=ready.release.skipped tex=\(frameUpdater.textureIdentifier)")
      return
    }
    hasDecodableFrame = true

    let sendInitialized = initializedPending
    let sendReloadingEnd = reloadingEndPending
    initializedPending = false
    reloadingEndPending = false
    if sendInitialized || sendReloadingEnd {
      Task {
        // The reports are async, so the item may have been stopped or replaced in the meantime.
        guard !disposed, player.currentItem?.status == .readyToPlay else { return }
        if sendInitialized {
          await super.reportInitialized()
        }
        if sendReloadingEnd {
          await super.finishLoadingNewAsset()
        }
      }
    }
    expectFrame()
  }

  /// Invalidates a pending first-frame timeout and drops any readiness it holds, for when the item
  /// it was held for has been discarded.
  private func abandonFirstFrameWait() {
    firstFrameWaitGeneration += 1
    initializedPending = false
    reloadingEndPending = false
  }

  /// Drives the texture at the video's content rate instead of every vsync.
  private func applyContentFrameRate(_ nominalFrameRate: Float) {
    // An unknown content rate (e.g. some HLS streams) keeps the self-refresh behavior, which updates
    // the texture every vsync.
    if disposed || nominalFrameRate <= 0 { return }

    // On a ProMotion display a 30 fps video then composites ~30x/s rather than 120x/s. The display
    // link becomes the sole driver, so the copyPixelBuffer self-refresh loop, which would otherwise
    // re-arm every vsync, is turned off.
    let contentFrameDuration = 1.0 / CFTimeInterval(nominalFrameRate)
    frameUpdater.contentFrameDuration = contentFrameDuration
    frameUpdater.frameDuration = contentFrameDuration
    selfRefresh = false
    displayLink?.preferredFrameRate = nominalFrameRate
  }

  // MARK: Latest pixel buffer

  private func replaceLatestPixelBuffer(_ buffer: CVPixelBuffer?) {
    latestPixelBufferLock.lock()
    defer { latestPixelBufferLock.unlock() }
    latestPixelBuffer = buffer
  }

  /// Returns an owned reference to the latest buffer, as the engine expects.
  private func copyLatestPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    latestPixelBufferLock.lock()
    defer { latestPixelBufferLock.unlock() }
    return latestPixelBuffer.map { Unmanaged.passRetained($0) }
  }

  private var hasLatestPixelBuffer: Bool {
    latestPixelBufferLock.lock()
    defer { latestPixelBufferLock.unlock() }
    return latestPixelBuffer != nil
  }

  // MARK: FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    // The engine is compositing this texture, so it is being consumed. Reset the counter that backs
    // off the display link once the texture goes offscreen (see FVPFrameUpdater displayLinkFired).
    frameUpdater.unconsumedFrameCount = 0

    if isPlaying {
      pausedRefreshCount = 0
    } else {
      pausedRefreshCount += 1
      if pausedRefreshCount % 600 == 0 {
        NSLog(
          "[VideoDiag] copyPixelBuffer churning while paused: %@",
          "\(pausedRefreshCount) calls (texture \(frameUpdater.textureIdentifier), "
            + "waitingForFrame=\(waitingForFrame), "
            + "displayLink running=\(displayLink?.running ?? false))")
      }
    }

    // If the difference between target time and current time is longer than this fraction of frame
    // duration then reset target time.
    let resetThreshold = 0.5

    // Ensure video sampling at regular intervals. This function is not called at exact time intervals
    // so CACurrentMediaTime returns irregular timestamps which causes missed video frames. The range
    // outside of which targetTime is reset should be narrow enough to make possible lag as small as
    // possible and at the same time wide enough to avoid too frequent resets which would lead to
    // irregular sampling.
    // TODO: Ideally there would be a targetTimestamp of display link used by the flutter engine.
    // https://github.com/flutter/flutter/issues/159087
    let currentTime = CACurrentMediaTime()
    let duration = frameUpdater.frameDuration
    if abs(targetTime - currentTime) > duration * resetThreshold {
      targetTime = currentTime
    }
    targetTime += duration

    // Diagnostic: once the engine starts pulling, hold whatever the texture currently has for a
    // while, so the hole lasts long enough for a screen recorder to catch. Timed from the first pull
    // rather than the load, since the engine doesn't pull until the page is on screen.
    let holdMillis = FVPDiagPlaceholderHoldMs()
    if holdMillis > 0 && diagLoadTime > 0 {
      let now = wallClockMillis()
      if diagHoldUntil == 0 {
        diagHoldUntil = now + holdMillis
        FVPDiagLogMessage(
          "ev=hold.begin tex=\(frameUpdater.textureIdentifier) ms=\(Int(holdMillis)) "
            + "hasBuffer=\(hasLatestPixelBuffer ? 1 : 0)")
      }
      if now < diagHoldUntil {
        return copyLatestPixelBuffer()
      }
    }

    var buffer: CVPixelBuffer?
    if let pixelBufferSource = pixelBufferSource {
      let outputItemTime = pixelBufferSource.itemTime(forHostTime: targetTime)
      if pixelBufferSource.hasNewPixelBuffer(forItemTime: outputItemTime) {
        buffer = pixelBufferSource.copyPixelBuffer(
          forItemTime: outputItemTime,
          itemTimeForDisplay: nil)
        if let buffer = buffer {
          replaceLatestPixelBuffer(buffer)
        }
      }
    }

    if buffer != nil {
      waitingForFrame = false
      if !hasRenderedFirstFrame {
        hasRenderedFirstFrame = true
        // This runs on the raster thread, and events must reach Flutter from the main thread.
        DispatchQueue.main.async { [weak self] in
          guard let self = self, self.hasRenderedFirstFrame else { return }
          self.eventListener?.videoPlayerDidRenderFirstFrame()
        }
      }
    }

    if FVPDiagEnabled() && diagLoadTime > 0 {
      let now = wallClockMillis()
      if buffer != nil {
        FVPDiagLogMessage(
          "ev=frame.first tex=\(frameUpdater.textureIdentifier) "
            + "sinceLoadMs=\(now - diagLoadTime) placeholderServed=\(diagPlaceholderServed)")
        diagLoadTime = 0
      } else {
        // No new buffer, so the engine gets the latest one back, which is still the placeholder
        // installed by loadAsset.
        diagPlaceholderServed += 1
        if diagPlaceholderServed == 1 {
          FVPDiagLogMessage(
            "ev=placeholder.served tex=\(frameUpdater.textureIdentifier) "
              + "sinceLoadMs=\(now - diagLoadTime)")
        }
      }
    }

    // Stop the display link whenever the player is paused with no pending frame expectation, not
    // only when a buffer arrived. A paused player produces no new buffers, so a buffer-gated stop
    // could never trigger, and the selfRefresh loop below would keep the engine redrawing the last
    // layer tree every vsync.
    if !isPlaying && !waitingForFrame {
      displayLink?.running = false
    }

    // Calling textureFrameAvailable only from within displayLinkFired would require a non-trivial
    // solution to minimize missed video frames due to race between displayLinkFired, copyPixelBuffer
    // and place where is _textureFrameAvailable reset to false in the flutter engine.
    // TODO: Ideally FlutterTexture would support mode of operation where the copyPixelBuffer is
    // called always or some other alternative, instead of on demand by calling textureFrameAvailable.
    // https://github.com/flutter/flutter/issues/159162
    if displayLink?.running ?? false && selfRefresh {
      // The number of frames over which to measure average frame duration.
      let windowSize = 10
      // If measured average frame duration is shorter than this fraction of frame duration obtained
      // from display link then rely solely on refreshes from display link.
      let durationThreshold = 0.5
      // If duration changes by this fraction or more then reset average frame duration measurement.
      let resetFraction = 0.01

      if abs(duration - latestDuration) >= latestDuration * resetFraction {
        startTime = currentTime
        framesCount = 0
        latestDuration = duration
      }
      if framesCount == windowSize {
        let averageDuration = (currentTime - startTime) / Double(windowSize)
        if averageDuration < duration * durationThreshold {
          NSLog(
            "Warning: measured average duration between frames is unexpectedly short (%f/%f), "
              + "please report this to https://github.com/flutter/flutter/issues.",
            averageDuration, duration)
          selfRefresh = false
        }
        startTime = currentTime
        framesCount = 0
      }
      framesCount += 1

      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        frameUpdater.registry?.textureFrameAvailable(
          frameUpdater.textureIdentifier)
      }
    }

    return copyLatestPixelBuffer()
  }

  /// Called when the texture is unregistered.
  /// This method is used to clean up resources associated with the texture.
  func onTextureUnregistered(_ texture: any FlutterTexture) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if !disposed {
        dispose()
      }
    }
  }

}

/// Creates a 1x1 fully transparent buffer to stand in for the previous video's last frame while a
/// new one loads.
///
/// Transparent rather than opaque black: the engine composites it for the frame or two between the
/// page revealing the texture and the first decoded frame being pulled, and black would show there,
/// whereas transparent lets whatever the page draws behind the texture show instead.
private func makeTransparentPixelBuffer() -> CVPixelBuffer? {
  var buffer: CVPixelBuffer?
  let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
  guard
    CVPixelBufferCreate(kCFAllocatorDefault, 1, 1, kCVPixelFormatType_32BGRA, attributes, &buffer)
      == kCVReturnSuccess,
    let buffer = buffer
  else { return nil }
  CVPixelBufferLockBaseAddress(buffer, [])
  if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
    memset(baseAddress, 0, CVPixelBufferGetDataSize(buffer))
  }
  CVPixelBufferUnlockBaseAddress(buffer, [])
  return buffer
}

/// The wall clock in milliseconds, which diagnostics use rather than CACurrentMediaTime so they land
/// on the same timeline as the Dart side's logs.
private func wallClockMillis() -> Double {
  return Date().timeIntervalSince1970 * 1000
}
