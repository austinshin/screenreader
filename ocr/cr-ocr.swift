// cr-ocr — minimal on-device OCR CLI using Apple's Vision framework.
// Usage: cr-ocr <image-path>   → recognized text on stdout, top-to-bottom.
//
// Why this exists: Hammerspoon can snapshot windows but has no OCR binding.
// Vision runs entirely on-device (no cloud), which is a hard requirement for
// a tool that reads everything on the user's screen.
//
// Build: swiftc -O ocr/cr-ocr.swift -o bin/cr-ocr

import Foundation
import AppKit
import Vision

guard CommandLine.arguments.count > 1 else {
  FileHandle.standardError.write("usage: cr-ocr <image-path>\n".data(using: .utf8)!)
  exit(64)
}

let path = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: path),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
  FileHandle.standardError.write("cr-ocr: cannot read image: \(path)\n".data(using: .utf8)!)
  exit(66)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
// screen text is code, paths, UI labels — do NOT "autocorrect" it into English
request.usesLanguageCorrection = false

do {
  try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
} catch {
  FileHandle.standardError.write("cr-ocr: vision failed: \(error)\n".data(using: .utf8)!)
  exit(70)
}

// Vision's coordinate origin is bottom-left; sort observations into natural
// top-to-bottom reading order.
let lines = (request.results ?? [])
  .sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
  .compactMap { $0.topCandidates(1).first?.string }

print(lines.joined(separator: "\n"))
