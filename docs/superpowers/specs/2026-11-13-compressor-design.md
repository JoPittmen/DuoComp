# DuoComp: design

Date: 2026-11-13. Status: approved 2026-11-13 ("Run it").

Repo: `DuoComp` (this repo), embedded in Duo Control as the `DuoCompKit` framework, the same way DuoHome and DuoIPTV are.

## Goal

Turn booth recordings and phone clips into files ready for social posts: right shape, right size, right codec, in a queue. Apple's Compressor is the inspiration only; nothing is copied.

## Approaches considered

1. **New app mode, AVFoundation queue (recommended).** A `DuoComp` mode in the app switcher next to DuoPlay and the others. Uses `AVAssetReader`/`AVAssetWriter` with Apple's hardware encoders. Runs on iPhone, iPad and Mac.
2. Share-sheet only. Smaller, but a share extension needs its own App ID. Ruled out.
3. Mac only. Simplest encoder story, but most social clips start on the phone. Ruled out for v1.

## Fit with the rules

- No new App ID, extension, App Group or capability.
- Needs two Info.plist strings in `project.yml`: `NSPhotoLibraryUsageDescription` (pick videos) and `NSPhotoLibraryAddUsageDescription` (save results). Strings, not capabilities.

## Presets (v1)

| Preset | Size | Frame | Codec | Video bitrate | Audio |
|---|---|---|---|---|---|
| Reels / TikTok / Shorts | 1080×1920 | 9:16 | H.264 High | 8 Mbps | AAC 128k |
| Instagram Feed | 1080×1350 | 4:5 | H.264 High | 6 Mbps | AAC 128k |
| Square | 1080×1080 | 1:1 | H.264 High | 6 Mbps | AAC 128k |
| YouTube / Facebook 1080p | 1920×1080 | 16:9 | H.264 High | 10 Mbps | AAC 192k |
| X (Twitter) | 1280×720 | 16:9 | H.264 High | 5 Mbps | AAC 128k |
| Smaller file (HEVC) | source | source | HEVC | ~50% of source | AAC 128k |
| Audio only | n/a | n/a | AAC in .m4a | n/a | AAC 192k |

H.264 for everything uploaded, since every platform accepts it. Frame rate kept up to 30 fps (60 kept for the YouTube preset).

## Reframe and trim confirmation

The app checks every added file against the chosen preset. Only when it is worth asking does a confirmation sheet appear:

- **Reframe** when the source shape differs from the preset's by more than 4% (a 16:9 service video going to a 9:16 Reel). Choices: **Crop to Fill** (default, with a live preview you drag to move the frame) or **Fit with Bars**.
- **Trim** when the source is longer than the preset's limit (Reels/TikTok/Shorts 3:00, X 2:20). Choices: **Use First m:ss** (default), **Choose Range** (start and end), or **Keep Full Length**.

Files that already fit go straight to the queue with no prompt.

## Per-job options

- Output: Save to Photos (default) and/or Share Sheet. Mac: save to a chosen folder (default Movies/DuoCompress).

## Queue

- Add from Photos (`PhotosPicker`) or Files (`fileImporter`); Mac also takes drag and drop.
- One job encodes at a time; others wait. Each row: thumbnail, preset, progress, estimated size, Cancel.
- Keeps encoding briefly when the app goes to the background (`beginBackgroundTask`); if iOS stops it, the job is marked "Paused, tap to resume" and restarts.
- Finished jobs show result size and "saved X%". Queue persists between launches (JSON in Application Support); source files are referenced, not copied, when possible.

## UI

- iPhone: a list (queue) with a + button; tapping + picks media then shows a preset sheet. Job detail is a pushed view with preview, reframe and trim.
- iPad and Mac: split view: queue on the left, job inspector (preview, preset, reframe, trim) on the right.
- Follows the HIG via `apple-design-standards`; standard controls, SF Symbol `rectangle.compress.vertical`.

## Code layout

```
DuoComp/Sources/DuoComp/
  CompRoot.swift            root view, queue list, add flow
  CompQueue.swift           @Observable queue, persistence, Photos save
  CompJob.swift             job model and state
  CompPreset.swift          preset catalog, crop math, advice (when to prompt)
  CompEncoder.swift         AVAssetReader/Writer pipeline, crop/scale via video composition
  CompConfirmSheet.swift    reframe and trim confirmation
```

Register `.comp` in Duo Control's `AppMode` (iOS first; the Mac app follows). Run `xcodegen generate` after adding files; check basenames are unique.

## Testing

- Unit tests: preset math (crop rect for each source/target shape), size estimate, queue state transitions.
- Encode test on a short bundled sample in the test target only (generated with AVFoundation, no third-party media).
- Manual: a real service clip on JoFone, upload result to Instagram and YouTube.

## Out of v1

Custom presets editor, captions/burn-in, watermark, batch apply to many files, uploading directly to platforms, watch or tvOS.
