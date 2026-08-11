# Voices in View

Voices in View is a privacy-first iPhone captioning app for in-person conversations. It uses Apple's on-device Speech framework and can mix a two-channel USB microphone, such as DJI Mic Mini, into one low-latency caption stream.

## Why this exists

FaceTime's live captions made phone conversations dramatically more accessible for my dad, who is hard of hearing. In-person family conversations are still difficult: several people may be talking from different places in a room while the phone sits too far away to capture everyone clearly.

Our research and early testing led to a simple product thesis: for group conversations, speech-to-text quality is often limited less by the choice of transcription model than by the distance between each speaker and the microphone. Even an excellent model struggles when speech arrives faint, reverberant, or buried in room noise. Moving a wearable microphone close to each speaker improves the signal before transcription begins.

That cleaner input gives us more freedom in the rest of the system. Instead of sending sensitive family conversations to a large cloud model, Voices in View can use an efficient Apple model entirely on the iPhone while still producing useful captions with low latency. Raw audio never needs to be recorded or uploaded.

The initial design is deliberately simple:

`two wearable mics → stereo USB receiver → one mixed audio stream → on-device SpeechTranscriber → large live captions`

Both microphones feed one chronological transcript. We intentionally avoid automatic speaker attribution: the person reading the captions can usually see who is speaking, while attribution would add duplicate captions, compute cost, and new ways to be wrong. The goal is not to claim a better private model than FaceTime uses; it is to give an on-device model much better source audio.

Apple describes `SpeechTranscriber` as suitable for live, long-form, and distant speech in its [SpeechAnalyzer overview](https://developer.apple.com/videos/play/wwdc2025/277/). DJI's two-transmitter receivers provide the close-mic USB input used by this prototype.

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
