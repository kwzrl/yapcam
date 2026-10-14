# Team render (YapcamRender: compositor, preview, export)

Own: `Sources/YapcamRender/**`, `Tests/YapcamRenderTests/**`.
Implement the `YapcamRender` surface in `docs/SWIFT_API.md`. You consume `Project` /
`YcFrame` from YapcamCore; until core lands, build against a local test double
inside your own tests, not by editing core.

## M1
1. Frame sources: per segment + track, decode with AVAssetReader / AVPlayerItemVideoOutput
   to CVPixelBuffers backed by IOSurface → Metal textures via CVMetalTextureCache
   (no CPU copies). Random access with a small cache for scrubbing.
2. `FrameCompositor`: draws a `YcFrame` — background (solid/gradient/image/blurred),
   rounded screen with shadow + inset, crop/zoom, motion blur during zoom moves,
   cursor sprite (from cursors.json) with scale/opacity, click effect, camera bubble
   (shape, radius, mirror). Color: sRGB in, correct gamma, no banding.
3. `PreviewPlayer` + `PreviewView` (MTKView, display link), play/pause/seek,
   audio playback synced to the frame clock (AVAudioEngine or AVPlayer for audio
   with the same clip mapping).
4. `Exporter`: offline loop over timeline at settings.fps → compositor → AVAssetWriter
   (H.264/HEVC, MP4/MOV, 720p–4K, 24/30/60 fps), audio mixed per clips + gains,
   progress, cancellation (removes partial file), verification of the result
   (reopen, check duration ± 1 frame, track count) before reporting success.

## M2
GIF export, export presets from FEATURES.md, quality/bitrate options, export of
a time range, performance numbers (export speed ×realtime, preview fps at 1080p/4K).

## Tests
Pixel tests: render known YcFrames against synthetic sources and compare to expected
images with tolerance; export a synthetic project and verify with AVAsset + ffprobe;
A/V sync test using a synthetic flash+beep source (offset < 1 frame).
