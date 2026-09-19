import Foundation
import Vision
import AppKit

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: swift e2e_ocr.swift <image_path>\n", stderr)
    exit(1)
}

let imagePath = CommandLine.arguments[1]
let url = URL(fileURLWithPath: imagePath)

guard let image = NSImage(contentsOf: url),
      let tiffData = image.tiffRepresentation,
      let bitmapImage = NSBitmapImageRep(data: tiffData),
      let cgImage = bitmapImage.cgImage else {
    fputs("Error: Could not load image at \(imagePath)\n", stderr)
    exit(1)
}

struct Box: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct LineResult: Codable {
    let text: String
    let confidence: Float
    let box: Box
}

struct OCRResult: Codable {
    let text: String
    let lines: [LineResult]
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

do {
    try handler.perform([request])
} catch {
    fputs("Error performing text recognition: \(error)\n", stderr)
    exit(1)
}

guard let observations = request.results else {
    print("{\"text\": \"\", \"lines\": []}")
    exit(0)
}

var lines: [LineResult] = []
var fullTextParts: [String] = []

// Vision coordinate system has (0, 0) at bottom-left. Sort from top to bottom.
let sortedObservations = observations.sorted { obs1, obs2 in
    if abs(obs1.boundingBox.origin.y - obs2.boundingBox.origin.y) > 0.02 {
        return obs1.boundingBox.origin.y > obs2.boundingBox.origin.y
    }
    return obs1.boundingBox.origin.x < obs2.boundingBox.origin.x
}

for observation in sortedObservations {
    guard let candidate = observation.topCandidates(1).first else { continue }
    let bb = observation.boundingBox
    let box = Box(x: Double(bb.origin.x), y: Double(bb.origin.y), width: Double(bb.size.width), height: Double(bb.size.height))
    lines.append(LineResult(text: candidate.string, confidence: candidate.confidence, box: box))
    fullTextParts.append(candidate.string)
}

let ocrResult = OCRResult(text: fullTextParts.joined(separator: "\n"), lines: lines)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
if let jsonData = try? encoder.encode(ocrResult),
   let jsonString = String(data: jsonData, encoding: .utf8) {
    print(jsonString)
} else {
    fputs("Error encoding JSON\n", stderr)
    exit(1)
}
