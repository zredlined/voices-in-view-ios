# Voices in View

Voices in View is a privacy-first iPhone captioning app for in-person conversations. It uses Apple's on-device Speech framework and can mix a two-channel USB microphone, such as DJI Mic Mini, into one low-latency caption stream.

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
4. For DJI Mic Mini, use the phone USB-C adapter, power on the receiver, and double-press the link button until its status LED is cyan (Stereo).
5. Run the app, open Diagnostics, and confirm that the input is USB and exposes two channels.

The first release intentionally downmixes all available channels into one Apple `SpeechTranscriber`. Raw audio is never written to disk.

## Privacy modes

- **Saved:** finalized caption text is stored locally with complete file protection and excluded from backup.
- **Ghost:** captions remain in memory for the live session and no transcript files are created.

See [docs/privacy.md](docs/privacy.md) for the user-facing privacy policy draft.
