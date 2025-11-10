//  AVAssetTimeSelector.swift
//  PryntTrimmerView – safer main-thread version
//
//  Created by Henry on 06/04/2017.
//  Updated: main-thread enforcement + layout deferral

import UIKit
import AVFoundation

/// Displays an AVAsset inside a scroll view with thumbnails and maps
/// time <-> scroll position.
@MainActor
public class AVAssetTimeSelector: UIView, UIScrollViewDelegate {

    let assetPreview = AssetVideoScrollView()

    /// Maximum duration shown in the strip (affects horizontal scaling)
    public var maxDuration: Double = 15 {
        didSet { assetPreview.maxDuration = maxDuration }
    }

    /// The asset to display. Thumbnails are regenerated when this changes.
    public var asset: AVAsset? {
        didSet {
            guard let asset = asset else { return }
            // If we don't yet have a non-zero layout, defer until after layout pass.
            if bounds.height <= 0 || bounds.width <= 0 {
                pendingAssetForLayout = asset
                setNeedsLayout()
            } else {
                assetDidChange(newAsset: asset)
            }
        }
    }

    // MARK: - Init

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupSubviews()
    }

    // MARK: - Layout deferral

    private var pendingAssetForLayout: AVAsset?

    public override func layoutSubviews() {
        super.layoutSubviews()
        if let pending = pendingAssetForLayout, bounds.height > 0, bounds.width > 0 {
            pendingAssetForLayout = nil
            assetDidChange(newAsset: pending)
        }
    }

    // MARK: - Setup

    func setupSubviews() {
        setupAssetPreview()
        constrainAssetPreview()
    }

    public func regenerateThumbnails() {
        if let asset = asset {
            assetPreview.regenerateThumbnails(for: asset)
        }
    }

    // MARK: - Asset Preview

    func setupAssetPreview() {
        translatesAutoresizingMaskIntoConstraints = false
        assetPreview.translatesAutoresizingMaskIntoConstraints = false
        assetPreview.delegate = self
        addSubview(assetPreview)
    }

    func constrainAssetPreview() {
        NSLayoutConstraint.activate([
            assetPreview.leftAnchor.constraint(equalTo: leftAnchor),
            assetPreview.rightAnchor.constraint(equalTo: rightAnchor),
            assetPreview.topAnchor.constraint(equalTo: topAnchor),
            assetPreview.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func assetDidChange(newAsset: AVAsset) {
        // Always regenerate on main (class is @MainActor, so this is guaranteed)
        assetPreview.regenerateThumbnails(for: newAsset)
    }

    // MARK: - Time & Position Equivalence

    var durationSize: CGFloat { assetPreview.contentSize.width }

    func getTime(from position: CGFloat) -> CMTime? {
        guard let asset = asset, durationSize > 0 else { return nil }
        let normalizedRatio = max(min(1, position / durationSize), 0)
        let positionTimeValue = Double(normalizedRatio) * Double(asset.duration.value)
        return CMTime(value: Int64(positionTimeValue), timescale: asset.duration.timescale)
    }

    func getPosition(from time: CMTime) -> CGFloat? {
        guard let asset = asset, asset.duration.value != 0 else { return nil }
        let timeRatio = CGFloat(time.value) * CGFloat(asset.duration.timescale) /
                        (CGFloat(time.timescale) * CGFloat(asset.duration.value))
        return timeRatio * durationSize
    }
}
