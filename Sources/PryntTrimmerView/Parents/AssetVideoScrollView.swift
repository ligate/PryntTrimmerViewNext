//  AssetVideoScrollView.swift
//  PryntTrimmerView – safer main-thread version
//
//  Updated: @MainActor + strict main-queue UI, bounds guards, clean generator callbacks

import AVFoundation
import UIKit

@MainActor
final class AssetVideoScrollView: UIScrollView {

    // MARK: - Public
    public var maxDuration: Double = 15

    // MARK: - Private
    private let contentView = UIView()
    private var widthConstraint: NSLayoutConstraint?
    private var generator: AVAssetImageGenerator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupSubviews()
    }

    deinit {
        generator?.cancelAllCGImageGeneration()
        generator = nil
    }

    private func setupSubviews() {
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        clipsToBounds = true

        contentView.backgroundColor = .clear
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.tag = -1
        addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.leftAnchor.constraint(equalTo: leftAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        widthConstraint = contentView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 1.0)
        widthConstraint?.isActive = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentSize = contentView.bounds.size
    }

    // MARK: - Thumbnails

    func regenerateThumbnails(for asset: AVAsset) {
        // UI is @MainActor; assert in debug
        assert(Thread.isMainThread)

        // If we don't have geometry yet, defer one tick.
        guard bounds.width > 0, bounds.height > 0 else {
            DispatchQueue.main.async { [weak self] in
                self?.regenerateThumbnails(for: asset)
            }
            return
        }

        guard let thumbnailSize = getThumbnailFrameSize(from: asset),
              thumbnailSize.width > 0, thumbnailSize.height > 0 else {
            // Unable to compute a sensible tile size (e.g. no track yet)
            return
        }

        // Cancel any prior work immediately
        generator?.cancelAllCGImageGeneration()

        // Remove old tiles (UI change → main)
        removeFormerThumbnails()

        // Update content width (based on duration vs maxDuration)
        let newContentSize = setContentSize(for: asset)

        // Compute counts using realized bounds
        let visibleThumbnailsCount = max(1, Int(ceil(bounds.width / thumbnailSize.width)))
        let thumbnailCount = max(1, Int(ceil(newContentSize.width / thumbnailSize.width)))

        addThumbnailViews(thumbnailCount, size: thumbnailSize)

        let timesForThumbnails = getThumbnailTimes(for: asset, numberOfThumbnails: thumbnailCount)

        generateImages(for: asset,
                       at: timesForThumbnails,
                       with: thumbnailSize,
                       visibleThumbnails: visibleThumbnailsCount)
    }

    private func getThumbnailFrameSize(from asset: AVAsset) -> CGSize? {
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }

        // Use absolute natural size after transform (rotation may flip signs)
        let transformed = track.naturalSize.applying(track.preferredTransform)
        let videoW = abs(transformed.width)
        let videoH = abs(transformed.height)

        let targetH = max(1, bounds.height) // ensure non-zero height
        guard videoW > 0, videoH > 0 else { return nil }

        let ratio = videoW / videoH
        guard ratio.isFinite && ratio > 0 else { return nil }

        let targetW = targetH * ratio
        return CGSize(width: targetW, height: targetH)
    }

    private func removeFormerThumbnails() {
        contentView.subviews.forEach { $0.removeFromSuperview() }
    }

    private func setContentSize(for asset: AVAsset) -> CGSize {
        let duration = max(asset.duration.seconds, 0.001)
        let factor = CGFloat(max(1.0, duration / max(maxDuration, 0.001)))

        widthConstraint?.isActive = false
        widthConstraint = contentView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: factor)
        widthConstraint?.isActive = true

        // Realize new bounds before computing counts
        layoutIfNeeded()
        return contentView.bounds.size
    }

    private func addThumbnailViews(_ count: Int, size: CGSize) {
        guard count > 0 else { return }
        for index in 0..<count {
            let imageView = UIImageView(frame: .zero)
            imageView.clipsToBounds = true
            imageView.contentMode = .scaleAspectFill // fill to avoid gaps
            imageView.tag = index

            // Position
            let originX = CGFloat(index) * size.width
            let maxWidth = contentView.bounds.width

            // Clamp last tile to not exceed content width
            let remaining = maxWidth - originX
            let tileWidth = max(0, min(size.width, remaining))

            imageView.frame = CGRect(x: originX, y: 0, width: tileWidth, height: size.height)
            contentView.addSubview(imageView)
        }
    }

    private func getThumbnailTimes(for asset: AVAsset, numberOfThumbnails: Int) -> [NSValue] {
        let duration = asset.duration
        let durationMs = max(duration.seconds, 0.001) * 1000.0
        let step = durationMs / Double(max(1, numberOfThumbnails))

        var times = [NSValue]()
        times.reserveCapacity(max(1, numberOfThumbnails))

        // Sample in the center of each tile interval; keep strictly before end
        for i in 0..<max(1, numberOfThumbnails) {
            let ms = min(durationMs - 1.0, (Double(i) + 0.5) * step)
            let cmTime = CMTime(value: Int64(ms), timescale: 1000)
            times.append(NSValue(time: cmTime))
        }
        return times
    }

    private func generateImages(for asset: AVAsset,
                                at times: [NSValue],
                                with maximumSize: CGSize,
                                visibleThumbnails: Int) {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true

        // Exact frame requests for crisp strips
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter  = .zero

        // Retina-aware max size
        let scale = UIScreen.main.scale
        gen.maximumSize = CGSize(width: maximumSize.width * scale,
                                 height: maximumSize.height * scale)

        // Swap in new generator after configuration (helps avoid races)
        generator = gen

        var index = 0
        gen.generateCGImagesAsynchronously(forTimes: times) { [weak self] _, cgImage, _, result, _ in
            guard let self = self, result == .succeeded, let cgImage = cgImage else { return }
            // UI update strictly on main
            DispatchQueue.main.async {
                if index == 0 {
                    self.displayFirstImage(cgImage, visibleThumbnails: visibleThumbnails)
                }
                self.displayImage(cgImage, at: index)
                index += 1
            }
        }
    }

    private func displayFirstImage(_ cgImage: CGImage, visibleThumbnails: Int) {
        guard visibleThumbnails > 0 else { return }
        for i in 0..<visibleThumbnails {
            displayImage(cgImage, at: i)
        }
    }

    private func displayImage(_ cgImage: CGImage, at index: Int) {
        guard let imageView = contentView.viewWithTag(index) as? UIImageView else { return }
        imageView.image = UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }
}
