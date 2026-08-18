# AirPods Far Field engineering notes

These notes document the feasibility research, safety constraints, and quality protocol behind the AirPods Far Field input. The feature uses AirPods worn by the person reading captions and is intended to improve capture of a person across the room while preserving the listener's separately configured AirPods hearing assistance.

## Feasibility

The microphone side is feasible with public iOS APIs:

- iOS 26 exposes Bluetooth high-quality recording for supported AirPods. Apple describes it as full-bandwidth Bluetooth input and output with media-oriented tuning. It can add latency and is not available in the European Union.
- iOS 26.2 exposes `AVAudioSession.CategoryOptions.farFieldInput`. It requires Bluetooth HFP and lets the app query whether the connected Bluetooth microphone supports far-field capture and whether the request actually became active.
- iOS 26's `AVInputPickerInteraction` provides a system microphone picker, but this experiment intentionally uses profile-driven automatic routing so an incompatible iPhone input cannot be selected under the Far Field profile.

The hearing-assistance side needs a physical-device experiment:

- AirPods Hearing Aid amplifies the environment only in Transparency mode. Apple also documents that Hearing Aid amplification and device media have separate levels and can be blended.
- A third-party app cannot enable, change, or query Hearing Aid, Transparency, Conversation Boost, or amplification level. The public audio-session API only reports the app's input and output route and Bluetooth microphone capture capabilities.
- The experiment therefore uses a bidirectional `playAndRecord` route so AirPods remain the matching output when their microphone is selected. It does not play the captured microphone back into the AirPods; that would add latency and risk acoustic feedback. Environmental passthrough remains AirPods' own low-latency Hearing Aid/Transparency path.
- Because iOS provides no programmatic proof that passthrough is still audible, listening comfort remains part of the manual experiment protocol rather than an in-app setting or gate.

Treat simultaneous Hearing Aid plus app capture as **promising but not yet proven** until it passes the checks below on the intended AirPods model, firmware, iPhone, iOS version, and region.

Apple references:

- [Far-field input option](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/farfieldinput)
- [Bluetooth high-quality recording](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/bluetoothhighqualityrecording)
- [WWDC25: Enhance your app's audio recording capabilities](https://developer.apple.com/videos/play/wwdc2025/251/)
- [Use the Hearing Aid feature on AirPods Pro](https://support.apple.com/en-us/120992)
- [Roadmap issue #1](https://github.com/zredlined/voices-in-view-ios/issues/1)

## Product behavior

The Home screen provides three explicit microphone choices:

1. **iPhone** — uses the built-in microphone.
2. **USB** — uses the connected USB receiver.
3. **AirPods** — selects the active AirPods and requests far-field capture on iOS 26.2 or later. If multiple pairs have been discovered, the AirPods button allows choosing between them.

Bluetooth high-quality recording was investigated but intentionally left out of the experiment UI: it does not test the head-directed far-field hypothesis and adds another mode to explain.

The app reports the active input, matching output, sample rate, and far-field supported/enabled state in Diagnostics. A request is never presented as active unless the AirPods report it as enabled. If AirPods cease to be the active microphone, a running AirPods caption session stops instead of silently continuing with the iPhone microphone.

## Before each AirPods run

1. Wear the AirPods and confirm they are connected to the test iPhone.
2. Select **AirPods**.
3. The app automatically selects the active AirPods. If more than one pair is known, choose the intended pair from the AirPods button.
4. In Control Center, enable Hearing Aid or Transparency. Configure the desired amplification and Conversation Boost settings there.
5. Tap **Test** in the microphone card.
6. Confirm the input name is the AirPods, the meter moves when another person speaks, and you can still hear the room comfortably.
7. Leave the mic check running and tap **Start Captions**, or stop it first; both paths are supported.
8. Open Diagnostics during or immediately after setup. Record whether capture says **Far field enabled** or **Standard Bluetooth**.

Stop the run immediately if environmental hearing is reduced, uncomfortable, or unreliable. Selecting the iPhone or USB source is the safe outcome.

## Quality test protocol

Use the same 200–300 word conversational script for every run. Keep speaker, room, speaking volume, iPhone position, AirPods hearing settings, and background noise as consistent as practical. Do three repetitions of each condition.

| Run | Input profile | Distance | Head angle | Noise | Capability enabled | Hearing preserved | Word errors | First-caption latency | Dropouts |
| --- | --- | ---: | ---: | --- | --- | --- | ---: | ---: | ---: |
| A | iPhone / USB (iPhone mic) | 2 m | N/A | Quiet | Measurement | N/A |  |  |  |
| B | AirPods Far Field | 2 m | 0° | Quiet | Far field / fallback | Yes / No |  |  |  |
| C | AirPods Far Field | 2 m | 90° | Quiet | Far field / fallback | Yes / No |  |  |  |
| D | AirPods Far Field | 2 m | 180° | Quiet | Far field / fallback | Yes / No |  |  |  |
| E | DJI worn by speaker | 2 m | N/A | Quiet | USB | N/A |  |  |  |

Repeat A–E with realistic background speech or television noise. Add 1 m and 3 m distances if the first comparison is encouraging.

For each saved transcript, compare it against the source script:

`word error rate = (substitutions + deletions + insertions) / source word count`

Also note subjective listening quality, whether turning the head helped, battery use, route changes, and any moment when Hearing Aid/Transparency stopped or changed character. First-caption latency and dropped frames are available in Diagnostics. Raw audio remains neither stored nor uploaded.

## Decision bar

Continue toward productization only if all of these are true:

- Hearing Aid/Transparency remains usable for the full run with no recurring manual recovery.
- Diagnostics repeatedly reports the expected AirPods input and requested capability as enabled.
- Far field materially improves word error rate in realistic conversation without unacceptable latency or dropouts.
- Head direction helps consistently enough to explain to users without overpromising beam direction.
- Unsupported AirPods and route changes fall back visibly and safely.
