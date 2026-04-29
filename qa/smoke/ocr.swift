// qa/smoke/ocr.swift — minimal Vision wrapper used by the L3 smoke test.
//
// Reads an image from disk, runs VNRecognizeTextRequest over it, and prints
// each recognized line to stdout. Used to read the menu bar badge text from
// a screenshot without scraping NSStatusItem internals.
//
// Compile:
//   swiftc qa/smoke/ocr.swift -framework Vision -framework AppKit -O -o qa/smoke/ocr

import Foundation
import Vision
import AppKit

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: ocr <image-path>\n".utf8))
    exit(2)
}

let path = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: path),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("ocr: failed to load image at \(path)\n".utf8))
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
// Disable language correction so a literal "47%" isn't autocorrected to a word.
request.usesLanguageCorrection = false
// Menu bar text is small (~12px); request small-text recognition.
request.minimumTextHeight = 0.0

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
do {
    try handler.perform([request])
} catch {
    FileHandle.standardError.write(Data("ocr: vision error: \(error)\n".utf8))
    exit(1)
}

guard let results = request.results else { exit(0) }
for observation in results {
    if let candidate = observation.topCandidates(1).first {
        print(candidate.string)
    }
}
