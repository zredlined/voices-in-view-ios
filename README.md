<p align="center">
  <img src="VoicesInView/Resources/Assets.xcassets/AppIcon.appiconset/VoicesInViewIcon.png" width="128" alt="Voices in View app icon">
</p>

# Voices in View

[![Release](https://img.shields.io/github/v/release/zredlined/voices-in-view-ios?include_prereleases&sort=semver)](https://github.com/zredlined/voices-in-view-ios/releases)
[![iOS 26+](https://img.shields.io/badge/iOS-26%2B-000000?logo=apple)](https://developer.apple.com/ios/)
[![License](https://img.shields.io/github/license/zredlined/voices-in-view-ios)](LICENSE)

Voices in View turns in-person conversations into large, real-time captions on an iPhone. It is designed for people who are hard of hearing and brings a FaceTime Live Captions-style experience to family gatherings, meetings, and other conversations in the same room.

<p align="center">
  <img src="docs/assets/voices-in-view-demo.gif" width="320" alt="Voices in View starting a private live-caption session and transcribing speech in real time">
</p>

## Why this exists

FaceTime Live Captions changed how my dad, who is hard of hearing, can take part in phone conversations. In person, it is harder: several people may be spread around a room, and an iPhone on the table may not hear everyone clearly.

The main problem is often microphone distance. Speech recognition works better when the microphone is closer to the person speaking, before room noise and reverberation get mixed in. Voices in View can use the iPhone microphone, a compatible USB microphone such as DJI Mic Mini, or supported AirPods worn by the person reading captions.

Choose the input that fits the conversation, then Voices in View transcribes it with Apple's on-device `SpeechTranscriber`:

`iPhone / USB / AirPods → on-device transcription → live captions`

AirPods Far Field provides a hands-free, head-directed option. A two-transmitter USB system can instead place microphones close to multiple speakers; Voices in View mixes its channels into one easy-to-follow conversation feed.

The transcription runs locally. Raw audio is not recorded or uploaded. Saved sessions store finalized caption text on the device; Ghost Mode does not keep the transcript. Apple describes `SpeechTranscriber` as suitable for live, long-form, and distant speech in its [SpeechAnalyzer overview](https://developer.apple.com/videos/play/wwdc2025/277/).

## Requirements

- Xcode 26.6 or newer
- iOS 26 or newer
- A physical iPhone for speech-model and USB-audio validation

The project has no third-party dependencies. Before building from the command line, select the installed Xcode:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Alternatively, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## First device run

1. Open `VoicesInView.xcodeproj`.
2. Choose a personal development team for the VoicesInView target.
3. Connect an iPhone running iOS 26 and enable Developer Mode.
4. Run the app and choose **iPhone**, **USB**, or **AirPods** under Input.
5. Tap **Test** to check the selected microphone before starting captions.

For USB and AirPods setup details, see [Support](docs/support.md). Raw audio is never written to disk.

## Privacy modes

- **Save:** finalized caption text is stored locally with complete file protection and excluded from backup.
- **Ghost:** captions remain in memory for the live session and no transcript files are created.

See [docs/privacy.md](docs/privacy.md) for the user-facing privacy policy.

For setup help or troubleshooting, see [docs/support.md](docs/support.md).

The engineering notes and evaluation protocol for AirPods Far Field remain available in [docs/airpods-experiment.md](docs/airpods-experiment.md).

## License

Voices in View is available under the [Apache License 2.0](LICENSE).
