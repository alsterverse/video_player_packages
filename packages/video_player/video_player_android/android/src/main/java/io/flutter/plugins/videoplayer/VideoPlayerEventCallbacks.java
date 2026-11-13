// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.VisibleForTesting;
import io.flutter.plugin.common.BinaryMessenger;

final class VideoPlayerEventCallbacks implements VideoPlayerCallbacks {
  private final QueuingEventSink eventSink;
  private final @Nullable VideoEventsEventChannel eventChannel;
  // The plugin's identifier for this player, which is also the stream instance
  // name. Only used to name the player in VideoPlayerDiag lines; Android's
  // texture id cannot serve there because loadAsset replaces it.
  @NonNull private final String identifier;

  @VisibleForTesting
  interface EventChannelFactory {
    VideoEventsEventChannel create(
        BinaryMessenger messenger, VideoEventsStreamHandler handler, String identifier);
  }

  static VideoPlayerEventCallbacks bindTo(
      @NonNull BinaryMessenger binaryMessenger, @NonNull String identifier) {
    return bindTo(binaryMessenger, identifier, VideoEventsStreamHandler.Companion::register);
  }

  @VisibleForTesting
  static VideoPlayerEventCallbacks bindTo(
      @NonNull BinaryMessenger binaryMessenger,
      @NonNull String identifier,
      EventChannelFactory factory) {
    QueuingEventSink eventSink = new QueuingEventSink();
    final VideoEventsEventChannel eventChannel =
        factory.create(
            binaryMessenger,
            new VideoEventsStreamHandler() {
              @Override
              public void onListen(
                  Object arguments, @NonNull PigeonEventSink<PlatformVideoEvent> events) {
                eventSink.setDelegate(events);
              }

              @Override
              public void onCancel(Object arguments) {
                eventSink.setDelegate(null);
              }
            },
            identifier);
    return new VideoPlayerEventCallbacks(eventSink, eventChannel, identifier);
  }

  @VisibleForTesting
  static VideoPlayerEventCallbacks withSink(@NonNull QueuingEventSink eventSink) {
    return new VideoPlayerEventCallbacks(eventSink, null, "?");
  }

  private VideoPlayerEventCallbacks(
      @NonNull QueuingEventSink eventSink,
      @Nullable VideoEventsEventChannel eventChannel,
      @NonNull String identifier) {
    this.eventSink = eventSink;
    this.eventChannel = eventChannel;
    this.identifier = identifier;
  }

  @Override
  public void onInitialized(
      int width, int height, long durationInMs, int rotationCorrectionInDegrees) {
    VideoPlayerDiag.log("ev=initialized pid=%s", identifier);
    eventSink.success(
        new InitializationEvent(durationInMs, width, height, rotationCorrectionInDegrees));
  }

  @Override
  public void onReloadingStart() {
    eventSink.success(new ReloadingStartEvent(true));
  }

  @Override
  public void onReloadingEnd(int width, int height, long durationInMs, @Nullable Long textureId) {
    VideoPlayerDiag.log("ev=reloading.end pid=%s texId=%s", identifier, textureId);
    eventSink.success(new ReloadingEndEvent(durationInMs, (long) width, (long) height, textureId));
  }

  @Override
  public void onRenderedFirstFrame() {
    VideoPlayerDiag.log("ev=frame.first pid=%s", identifier);
    eventSink.success(new FirstFrameRenderedEvent(true));
  }

  @Override
  public void onPlaybackStateChanged(@NonNull PlatformPlaybackState state) {
    eventSink.success(new PlaybackStateChangeEvent(state));
  }

  @Override
  public void onError(@NonNull String code, @Nullable String message, @Nullable Object details) {
    eventSink.error(code, message, details);
  }

  @Override
  public void onIsPlayingStateUpdate(boolean isPlaying) {
    eventSink.success(new IsPlayingStateEvent(isPlaying));
  }

  @Override
  public void onAudioTrackChanged(@Nullable String selectedTrackId) {
    eventSink.success(new AudioTrackChangedEvent(selectedTrackId));
  }

  @Override
  public void onVideoTrackChanged(@Nullable String selectedTrackId) {
    eventSink.success(new VideoTrackChangedEvent(selectedTrackId));
  }

  @Override
  public void onDisposed() {
    if (eventChannel != null) {
      eventChannel.setStreamHandler(null);
    }
  }
}
