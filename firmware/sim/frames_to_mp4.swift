// Turns a list of images into an H.264 MP4 using macOS's built-in encoder (no ffmpeg needed).
//
//   swift sim/frames_to_mp4.swift manifest.tsv out.mp4
//
// manifest.tsv has one line per frame: "<milliseconds to show it>\t<path to image>".
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count == 3 else {
  fputs("usage: frames_to_mp4 manifest.tsv out.mp4\n", stderr)
  exit(2)
}

var frames: [(seconds: Double, path: String)] = []
for line in try String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n") {
  let parts = line.split(separator: "\t", maxSplits: 1)
  if parts.count == 2, let ms = Double(parts[0]) { frames.append((ms / 1000, String(parts[1]))) }
}
guard !frames.isEmpty else {
  fputs("manifest has no frames\n", stderr)
  exit(1)
}

func load(_ path: String) -> CGImage? {
  guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
  return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

guard let first = load(frames[0].path) else {
  fputs("cannot read \(frames[0].path)\n", stderr)
  exit(1)
}
// H.264 needs even dimensions.
let width = (first.width + 1) / 2 * 2
let height = (first.height + 1) / 2 * 2

let outURL = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: outURL)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
  AVVideoCodecKey: AVVideoCodecType.h264,
  AVVideoWidthKey: width,
  AVVideoHeightKey: height,
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
  kCVPixelBufferWidthKey as String: width,
  kCVPixelBufferHeightKey as String: height,
])
writer.add(input)
guard writer.startWriting() else {
  fputs("cannot start writing: \(String(describing: writer.error))\n", stderr)
  exit(1)
}
writer.startSession(atSourceTime: .zero)

func append(_ image: CGImage, at seconds: Double) {
  var pixelBuffer: CVPixelBuffer?
  CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
  guard let buffer = pixelBuffer else { return }
  CVPixelBufferLockBaseAddress(buffer, [])
  if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                         bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
    ctx.setFillColor(CGColor(red: 0.07, green: 0.09, blue: 0.11, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
  }
  CVPixelBufferUnlockBaseAddress(buffer, [])
  while !input.isReadyForMoreMediaData { usleep(2000) }
  adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
}

var t = 0.0
var last: CGImage? = nil
for frame in frames {
  guard let image = load(frame.path) else { continue }
  append(image, at: t)
  t += frame.seconds
  last = image
}
// Repeat the final image just before the end so players hold it for its full duration.
if let image = last, let final = frames.last, final.seconds > 0.1 { append(image, at: t - 0.05) }

input.markAsFinished()
writer.endSession(atSourceTime: CMTime(seconds: t, preferredTimescale: 600))
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
if writer.status != .completed {
  fputs("encoding failed: \(String(describing: writer.error))\n", stderr)
  exit(1)
}
print(String(format: "%d frames, %.1f s, %dx%d", frames.count, t, width, height))
