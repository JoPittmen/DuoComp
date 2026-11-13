# DuoComp v2: design

Date: 2026-11-13. Status: draft, awaiting approval. iPhone and iPad only.

Build order: Captions → Batch presets → Loudness → Cover frame → Speaker-following reframe (last).

## 1. Captions

- A **Captions** toggle in the confirmation sheet (the sheet now always opens when Captions is on).
- When it's on, a row of style options appears below it. The idea comes from Edits; the styles, fonts and wording are our own:
  - **Classic**: white text on a soft dark band, two lines.
  - **Bold**: large heavy white text with an outline, a few words at a time.
  - **Highlight**: the word being spoken changes to the accent color.
  - **Minimal**: small lower-third text, no band.
- Choices: where on screen (Top, Middle, Bottom) and the accent color.
- Speech to text runs on the device with Apple's `SpeechAnalyzer`, so audio never leaves the phone. Words keep their timings.
- **Edit Captions** screen: the transcript as a list of lines. Tap a line to fix the words; the timings stay.
- The captions are drawn into the picture during the encode through a Core Animation layer on the video composition.
- Needs the Speech Recognition permission string in `project.yml`. That's a string, not a capability.

## 2. Batch presets

- The preset picker allows more than one choice. Each file then becomes one job per preset.
- The reframe and trim question is asked once for each preset that needs it.

## 4. Loudness

- A **Level Audio** toggle, on by default for every video preset.
- It measures the loudness (ITU BS.1770) and sets the gain to −14 LUFS, with a peak limit of −1 dBTP. The work happens in the audio pump.

## 6. Cover frame

- A **Cover** row in the confirmation sheet. A scrubber picks the frame, which is shown already cropped to the preset.
- The cover is saved as a JPEG next to the video, and to Photos when that's turned on. It also appears in the share sheet.

## 5. Speaker-following reframe (last)

- A **Follow Speaker** choice in Reframe, next to Crop to Fill and Fit with Bars.
- Apple's Vision framework tracks the people in the shot. The crop path is smoothed, then encoded as a crop that moves over time.
- You can still drag the starting position.

## Out

Watermark, booth hand-off, Mac app, custom presets.

## As built (2026-11-13)

Status: approved ("Approved") and built.

- The Captions toggle, its styles and Level Audio live in the preset picker. They're chosen once for every file added together, so the reframe/trim sheet still opens only when it's needed.
- With Captions on, a job goes **Finding words → Captions ready to check**. Tapping **Check** opens a review sheet: a live preview of the frame with the caption on it, and the lines to edit. **Make Video** sends the job on to encode. Other jobs keep encoding while this one waits for the check.
- Captions are drawn onto each frame with CoreText. AVFoundation's Core Animation tool doesn't work with AVAssetReader.
- Speech to text uses `SFSpeechRecognizer`, on the device when supported. It's used over `SpeechAnalyzer` because its API is the proven one.
- Cover: the default frame is a tenth of the way in. **Choose Cover…** is in each row's menu instead of in the confirmation sheet.
- Level Audio caps the gain so peaks stay under −1 dBFS (sample peak), and never adds more than +20 dB. There's no separate limiter.
