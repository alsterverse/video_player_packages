// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import Foundation

/// Handles event/status callbacks from VideoPlayer.
///
/// This is an abstraction around the event channel to avoid coupling VideoPlayer directly to
/// implementation details specific to the plugin communication method.
@MainActor protocol VideoEventListener: AnyObject {
  /// Called when the video player has initialized.
  func videoPlayerDidInitialize(withDuration duration: Int64, size: CGSize)
  /// Called if there is an error in video load or playback.
  func videoPlayerDidError(withMessage errorMessage: String)
  /// Called when the video player plays to the end and then stops (i.e., looping is not enabled).
  func videoPlayerDidComplete()
  /// Called when the video player needs to buffer more in order to play without stopping.
  func videoPlayerDidStartBuffering()
  /// Called when the video player has buffered enough to likely be able to play without stopping.
  func videoPlayerDidEndBuffering()
  /// Called when the buffered regions change.
  ///
  /// Each element in the array represents a distinct buffered region.
  func videoPlayerDidUpdateBufferRegions(_ regions: [PlatformDurationRange])
  /// Called when the video player has started to load a new item.
  func videoPlayerDidStartReloading()
  /// Called when the video player has finished loading a new item.
  func videoPlayerDidEndReloading(withDuration duration: Int64, size: CGSize)
  /// Called the first time the engine is handed a decoded frame of the current
  /// asset -- that is, the first moment the texture has something to show.
  ///
  /// Readiness cannot say this: it is reported before the engine has asked the
  /// texture for anything, and the engine does not ask until the texture is on
  /// screen. A page that reveals the texture on readiness alone therefore reveals
  /// it a frame or so early, with nothing behind it.
  func videoPlayerDidRenderFirstFrame()
  /// Called when the player starts or stops playing.
  func videoPlayerDidSetPlaying(_ playing: Bool)
  /// Called when the video player has been disposed on the Dart side.
  func videoPlayerWasDisposed()
}
