#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO

struct Arguments {
    let input: URL
    let metadata: URL
    let output: URL
    let width: Int
    let height: Int
}

struct CropMetadata: Decodable {
    struct Rect: Decodable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    let screen_scale: CGFloat
    let crop_points: Rect
}

enum ProcessorError: Error, CustomStringConvertible {
    case missingValue(String)
    case invalidArguments
    case invalidDimension(String)
    case cannotLoadImage(String)
    case cannotCrop
    case cannotCreateContext
    case cannotCreateDestination(String)
    case cannotWriteOutput(String)

    var description: String {
        switch self {
        case .missingValue(let flag):
            return "Missing value after \(flag)"
        case .invalidArguments:
            return "Usage: process-simulator-preview-screenshot.swift --input PNG --metadata JSON --output PNG --width PX --height PX"
        case .invalidDimension(let value):
            return "Invalid dimension: \(value)"
        case .cannotLoadImage(let path):
            return "Could not load image: \(path)"
        case .cannotCrop:
            return "Could not crop screenshot to metadata rectangle"
        case .cannotCreateContext:
            return "Could not create output bitmap context"
        case .cannotCreateDestination(let path):
            return "Could not create image destination: \(path)"
        case .cannotWriteOutput(let path):
            return "Could not write output PNG: \(path)"
        }
    }
}

func parseArguments() throws -> Arguments {
    let raw = Array(CommandLine.arguments.dropFirst())

    func value(after flag: String) throws -> String {
        guard let index = raw.firstIndex(of: flag),
              raw.indices.contains(index + 1) else {
            throw ProcessorError.missingValue(flag)
        }
        return raw[index + 1]
    }

    let widthValue = try value(after: "--width")
    let heightValue = try value(after: "--height")
    guard let width = Int(widthValue), width > 0 else {
        throw ProcessorError.invalidDimension(widthValue)
    }
    guard let height = Int(heightValue), height > 0 else {
        throw ProcessorError.invalidDimension(heightValue)
    }

    return Arguments(
        input: URL(fileURLWithPath: try value(after: "--input")),
        metadata: URL(fileURLWithPath: try value(after: "--metadata")),
        output: URL(fileURLWithPath: try value(after: "--output")),
        width: width,
        height: height
    )
}

func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ProcessorError.cannotLoadImage(url.path)
    }
    return image
}

func cropRect(from metadata: CropMetadata, image: CGImage) -> CGRect {
    let scale = metadata.screen_scale
    let rect = CGRect(
        x: metadata.crop_points.x * scale,
        y: metadata.crop_points.y * scale,
        width: metadata.crop_points.width * scale,
        height: metadata.crop_points.height * scale
    ).integral

    return rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
}

func renderAspectFit(source: CGImage, width: Int, height: Int) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw ProcessorError.cannotCreateContext
    }

    context.clear(CGRect(x: 0, y: 0, width: width, height: height))

    let scale = min(CGFloat(width) / CGFloat(source.width), CGFloat(height) / CGFloat(source.height))
    let drawWidth = CGFloat(source.width) * scale
    let drawHeight = CGFloat(source.height) * scale
    let drawRect = CGRect(
        x: (CGFloat(width) - drawWidth) / 2,
        y: (CGFloat(height) - drawHeight) / 2,
        width: drawWidth,
        height: drawHeight
    )

    context.interpolationQuality = .high
    context.draw(source, in: drawRect)

    guard let image = context.makeImage() else {
        throw ProcessorError.cannotCreateContext
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw ProcessorError.cannotCreateDestination(url.path)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ProcessorError.cannotWriteOutput(url.path)
    }
}

do {
    let arguments = try parseArguments()
    let metadataData = try Data(contentsOf: arguments.metadata)
    let metadata = try JSONDecoder().decode(CropMetadata.self, from: metadataData)
    let screenshot = try loadImage(arguments.input)
    let rect = cropRect(from: metadata, image: screenshot)

    guard !rect.isNull, rect.width > 0, rect.height > 0,
          let cropped = screenshot.cropping(to: rect) else {
        throw ProcessorError.cannotCrop
    }

    let output = try renderAspectFit(source: cropped, width: arguments.width, height: arguments.height)
    try writePNG(output, to: arguments.output)
} catch let error as ProcessorError {
    fputs("\(error.description)\n", stderr)
    exit(1)
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
