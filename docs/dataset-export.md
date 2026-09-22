# Dataset export prototype (schema 0.1)

## Scope

Single international-Morse message, fixed speed/pitch, no receiver effects.
Reuses `VCL/MorseKey.pas`; this is NOT a recording of the contest GUI,
and does not yet include QSB, QRM, receiver filters, AGC, station scheduling,
number substitutions, or Japanese Morse. Input text is the literal emitted
text: supply `5NN`, not the semantic value `599`, when that is desired.

## Build on Windows

Verified with Lazarus 4.6 and FPC 3.2.2, x86_64-win64.
From the repository root (PowerShell):

```powershell
New-Item -ItemType Directory -Force lib/export | Out-Null
& C:/lazarus/fpc/3.2.2/bin/x86_64-win64/fpc.exe -B -FuVCL -FUlib/export -FElib/export tools/export_sample.lpr
& ./lib/export/export_sample.exe ./lib/example 'CQ CQ DE JI1UUI K' 20 700
& ./tests/test_export.ps1
```

The output directory must not exist; its final component is created
exclusively so concurrent exports cannot share/overwrite one session.
Text is 1..256 ASCII characters,
uppercase A-Z, digits, spaces, `/.,?=`; leading/trailing spaces and unsupported
characters are rejected. WPM is integer 5..60; pitch is 200..1200 Hz.
No randomness or audio device is used. Text is not silently normalized.

## Output contract

- `received.wav`: mono 22050 Hz, signed little-endian 16-bit PCM. Fixed
  carrier amplitude 12000, cosine phase zero at frame zero, original keyer
  attack/decay. Despite the filename, this prototype has NO receiver effects.
- `symbols.jsonl`: ordered logical dit/dah and gap intervals, UTF-8-compatible
  ASCII JSON. All coordinates refer to WAV sample frames, zero-based,
  half-open `[start_sample,end_sample)`. IDs are local to the output directory.
  `morse_index_1based` points into `message.json`'s encoded string. For gaps
  it references the preceding mark. Events end before buffer padding.
- `message.json`: emitted text, encoded sequence, station/message IDs and mode.
  In the upstream encoding a space is a gap extension, `~` an end extension.
- `manifest.json`: schema, signal parameters, coordinate convention, sample
  count, and completion status. Written LAST. Missing/malformed manifest means
  incomplete output; never ingest it as a completed dataset.

Logical mark starts are attack starts; logical ends are decay starts. The
decay extends into the following gap. These are not measured audible edges.
`trailing_gap` is message termination, NOT a learned word-boundary label.
Padding has no symbol labels and must not be treated as another word.
CTC blank is not a recorded physical gap event.

## Preserve legacy timing, do not certify it as ITU timing

For U=round(1.2*rate/WPM) and ramp length R, the existing keyer uses a
one-unit post-mark gap and adds `2U-R` for each encoded space. Therefore a
normal character gap is `3U-R`; a single input word-space gives `5U-2R`.
The final `~` adds `U-R`. Buffer padding is also retained. Instrumentation
records those actual coordinates rather than relabeling them as ideal 1:3:7.
This behavior predates this change and is deliberately not corrected here.
An explicitly versioned standard-timing mode is needed before this generator
is used as the sole source of standards-conforming training data.

## Verification and provenance

Pinned starting commit: `c55dbfb286031066f69add0a43d2c6df320e6788`.
`tests/test_export.ps1` compiles that unmodified keyer separately and compares
float envelopes for every integer speed 5..60 against the modified keyer.
The exporter also checks observer-off/on equality on every invocation.
The PowerShell test runner requires PowerShell 7 and builds the exporter
with range and overflow checks enabled. Tests validate PCM headers, sample extents, tone energy under mark labels,
repeated elements, character/word boundaries, rejection, overwrite protection,
deterministic WAV output, maximum input size, parameter boundaries and
concurrent output exclusion. Test evidence stays under ignored `lib/`.
Persist the source patch/commit and binary hashes with any shared dataset;
automatic source/build hashes and a session-wide manifest are future work.

GUI build was verified before and after the change with:

```powershell
& C:/lazarus/lazbuild.exe --primary-config-path=../lazarus-config --add-package-link BGRABitmap/bgrabitmap/bgrabitmappack.lpk uecontrols-master/uecontrols.lpk talsoundout/talsoundout.lpk
& C:/lazarus/lazbuild.exe --primary-config-path=../lazarus-config --os=win64 MorseRunner-Server.lpi
```

The isolated Lazarus profile avoids changing the user's normal package setup.
An Fppkg configuration warning occurred; compilation still succeeded.
GUI audio playback, Linux/macOS builds and long-running real-time behavior
have NOT been verified.

## Integration next

`Station.SendText -> Keyer.Encode -> Station.SendMorse -> Keyer.Envelope`
creates station envelopes; `Contest.GetAudio` (inspect exact caller on
integration) mixes station blocks, applies receiver processing and AGC.
The root `Wavfile.pas` reads noise WAVs; it is not a new labeled-session writer.
Live recording requires per-station event ownership, the final audio timeline,
receiver latency/mute events and a bounded writer queue. Do not attach the
file-writing collector to the shared live keyer. Do not emit repeated labels
when `MsgText` is re-encoded; commit only sample ranges actually rendered.
