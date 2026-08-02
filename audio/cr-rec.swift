// cr-rec — record the default input device to a 16 kHz mono WAV until SIGTERM.
// Usage: cr-rec <out.wav> [maxSeconds]
//
// Why this exists: Hammerspoon can bind a key but has no audio-capture binding,
// and macOS ships no recording CLI (there is afplay, afconvert, afinfo — no
// afrecord). Same reason bin/cr-ocr exists for Vision. swiftc is already a hard
// requirement of setup.sh, so this costs no new dependency.
//
// Why not ffmpeg: it works, and it is the fallback, but it needs 0.5–1.5s to
// open an AVCaptureSession — the worst possible place to spend latency in
// push-to-talk — and it reports a denied microphone and a busy device with the
// same "Input/output error". This tells the two apart, which decides whether
// the user should open System Settings or just try again.
//
// Protocol (stdout, line-buffered):
//   READY              once, the instant capture actually starts
//   LVL <peak-dBFS>    every 100ms while recording
//
// Exit codes:
//   0   stopped cleanly, WAV finalized
//   64  usage
//   74  device or write error
//   77  microphone permission denied  (EX_NOPERM)
//
// Build: swiftc -O audio/cr-rec.swift -o bin/cr-rec

import AVFoundation
import Foundation

// Line-buffer stdout, or READY/LVL sit in a 4KB buffer and the reader — which
// is waiting on exactly those lines — sees nothing until the process exits.
setvbuf(stdout, nil, _IOLBF, 0)

func die(_ msg: String, _ code: Int32) -> Never {
  FileHandle.standardError.write("cr-rec: \(msg)\n".data(using: .utf8)!)
  exit(code)
}

let args = CommandLine.arguments
guard args.count > 1 else { die("usage: cr-rec <out.wav> [maxSeconds]", 64) }
let outPath = args[1]
let maxSeconds = args.count > 2 ? (Double(args[2]) ?? 30.0) : 30.0

// Ask before recording. A denied mic is the one failure worth naming exactly:
// every other error tells the user to retry, this one tells them to open
// System Settings, and guessing wrong wastes their time either way.
let sem = DispatchSemaphore(value: 0)
var granted = false
switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
  granted = true
case .notDetermined:
  AVCaptureDevice.requestAccess(for: .audio) { ok in granted = ok; sem.signal() }
  sem.wait()
default:
  granted = false
}
guard granted else {
  die("microphone access denied — System Settings › Privacy & Security › Microphone", 77)
}

let settings: [String: Any] = [
  AVFormatIDKey: Int(kAudioFormatLinearPCM),
  AVSampleRateKey: 16000.0,          // whisper.cpp's native rate: no resample step
  AVNumberOfChannelsKey: 1,
  AVLinearPCMBitDepthKey: 16,
  AVLinearPCMIsFloatKey: false,
  AVLinearPCMIsBigEndianKey: false,
]

let url = URL(fileURLWithPath: outPath)
guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
  die("cannot open \(outPath) for writing", 74)
}
recorder.isMeteringEnabled = true

// SIGTERM must be ignored at the POSIX level FIRST. DispatchSourceSignal
// observes the signal, it does not replace the default disposition — leave the
// default in place and the process dies before stop() runs, leaving a WAV with
// a zeroed RIFF header that whisper reads as an empty file.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

func finish() -> Never {
  recorder.stop()          // writes the RIFF/data chunk sizes
  exit(0)
}

let termSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSrc.setEventHandler { finish() }
termSrc.resume()
let intSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
intSrc.setEventHandler { finish() }
intSrc.resume()

// A hard duration cap as well as the signal: if a key-up is ever missed, or the
// parent dies without signalling, this stops the disk filling up quietly.
guard recorder.record(forDuration: maxSeconds) else {
  die("could not start recording (device busy?)", 74)
}
print("READY")

// record(forDuration:) stops capturing at the cap but does not end the
// process — dispatchMain() would keep it alive forever holding the mic open.
// The cap has to terminate us too, or "recording stopped" and "recorder exited"
// are different events and the caller waits on one that never comes.
let cap = DispatchSource.makeTimerSource(queue: .main)
cap.schedule(deadline: .now() + maxSeconds + 0.2)
cap.setEventHandler { finish() }
cap.resume()

// Peak level, published for the caller. This is what lets "the mic is muted"
// be a different message from "I didn't understand you" — they need different
// fixes, and reporting the wrong one sends the user to the wrong place.
let meter = DispatchSource.makeTimerSource(queue: .main)
meter.schedule(deadline: .now() + 0.1, repeating: 0.1)
meter.setEventHandler {
  guard recorder.isRecording else { return }
  recorder.updateMeters()
  print(String(format: "LVL %.1f", recorder.peakPower(forChannel: 0)))
}
meter.resume()

// A CLI has no run loop of its own; without this AVAudioRecorder never
// delivers anything and the timers never fire.
dispatchMain()
