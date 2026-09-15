@preconcurrency import AVFoundation
import CoreVideo
import Metal
import QuartzCore

struct VideoFrame {
    let pixelBuffer: CVPixelBuffer
    let metalTexture: CVMetalTexture
    let texture: any MTLTexture
    let itemTime: CMTime
}

enum VideoSourceError: Error, CustomStringConvertible {
    case noVideoTrack
    case textureCacheCreationFailed(CVReturn)
    case textureCreationFailed(CVReturn)
    case missingMetalTexture

    var description: String {
        switch self {
        case .noVideoTrack:
            return "The input does not contain a video track"
        case let .textureCacheCreationFailed(status):
            return "CVMetalTextureCacheCreate failed with status \(status)"
        case let .textureCreationFailed(status):
            return "CVMetalTextureCacheCreateTextureFromImage failed with status \(status)"
        case .missingMetalTexture:
            return "CoreVideo created a CVMetalTexture without an MTLTexture"
        }
    }
}

@MainActor
final class VideoSource {
    let url: URL
    let player: AVPlayer
    let videoOutput: AVPlayerItemVideoOutput
    let displaySize: CGSize
    let duration: CMTime

    private let textureCache: CVMetalTextureCache

    // Keep a small ring of IOSurface/CVMetalTexture owners alive after a frame
    // has been handed to Metal. SwiftXR deliberately does not CPU-wait on every
    // command buffer, so dropping the latest CVPixelBuffer immediately would be
    // an unnecessary lifetime gamble.
    private var retainedFrames: [VideoFrame] = []
    private let retainedFrameLimit = 16

    private init(
        url: URL,
        player: AVPlayer,
        videoOutput: AVPlayerItemVideoOutput,
        displaySize: CGSize,
        duration: CMTime,
        textureCache: CVMetalTextureCache
    ) {
        self.url = url
        self.player = player
        self.videoOutput = videoOutput
        self.displaySize = displaySize
        self.duration = duration
        self.textureCache = textureCache
    }

    static func open(
        url: URL,
        device: any MTLDevice
    ) async throws -> VideoSource {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw VideoSourceError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let transformedBounds = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
        var displaySize = CGSize(
            width: abs(transformedBounds.width),
            height: abs(transformedBounds.height)
        )
        if displaySize.width < 1 || displaySize.height < 1 {
            displaySize = CGSize(
                width: abs(naturalSize.width),
                height: abs(naturalSize.height)
            )
        }

        let duration = try await asset.load(.duration)

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let videoOutput = AVPlayerItemVideoOutput(
            pixelBufferAttributes: pixelBufferAttributes
        )

        let item = AVPlayerItem(asset: asset)
        item.add(videoOutput)

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true

        var optionalCache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &optionalCache
        )
        guard cacheStatus == kCVReturnSuccess, let textureCache = optionalCache else {
            throw VideoSourceError.textureCacheCreationFailed(cacheStatus)
        }

        return VideoSource(
            url: url,
            player: player,
            videoOutput: videoOutput,
            displaySize: displaySize,
            duration: duration,
            textureCache: textureCache
        )
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    var durationSeconds: Double? {
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    var currentTimeSeconds: Double {
        let seconds = CMTimeGetSeconds(player.currentTime())
        return seconds.isFinite ? seconds : 0
    }

    var failureDescription: String? {
        player.currentItem?.error?.localizedDescription
    }

    /// Return the newest decoded frame, or the previous frame if AVFoundation
    /// has not advanced since the last XR render tick.
    func latestFrame() throws -> VideoFrame? {
        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())

        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else {
            return retainedFrames.last
        }

        guard let pixelBuffer = videoOutput.copyPixelBuffer(
            forItemTime: itemTime,
            itemTimeForDisplay: nil
        ) else {
            return retainedFrames.last
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var optionalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &optionalTexture
        )
        guard status == kCVReturnSuccess, let metalTexture = optionalTexture else {
            throw VideoSourceError.textureCreationFailed(status)
        }
        guard let texture = CVMetalTextureGetTexture(metalTexture) else {
            throw VideoSourceError.missingMetalTexture
        }

        let frame = VideoFrame(
            pixelBuffer: pixelBuffer,
            metalTexture: metalTexture,
            texture: texture,
            itemTime: itemTime
        )
        retainedFrames.append(frame)
        if retainedFrames.count > retainedFrameLimit {
            retainedFrames.removeFirst(retainedFrames.count - retainedFrameLimit)
        }
        return frame
    }
}
