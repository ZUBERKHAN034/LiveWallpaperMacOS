/*
 * This file is part of LiveWallpaper – LiveWallpaper App for macOS.
 * Copyright (C) 2025 Bios thusvill
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import AVFoundation
import AppKit
import CommonCrypto
import CoreMedia
import CoreVideo
import VideoToolbox

/// Injects a video into Apple's aerial wallpaper catalog so it plays
/// on the macOS lock screen via WallpaperAerialsExtension (Tahoe)
/// or idleassetsd (Sequoia). No user interaction needed after initial
/// System Settings category selection.
@objc(AerialCatalogManager)
final class AerialCatalogManager: NSObject, @unchecked Sendable {

    @objc static let shared = AerialCatalogManager()

    // Serial actor — prevents concurrent entries.json writes from racing
    private actor SyncGate {
        private var task: Task<Void, Never>?
        func enqueue(_ work: @escaping @Sendable () async -> Void) {
            let previous = task
            task = Task { [previous] in
                await previous?.value
                await work()
            }
        }
    }
    private let gate = SyncGate()

    // MARK: - UUIDv5 namespace (matching phonto — must be stable)
    private static let namespaceBytes: [UInt8] = [
        0x70, 0x68, 0x6F, 0x6E, 0x74, 0x6F, 0x77, 0x70,
        0x70, 0x72, 0x6F, 0x6A, 0x65, 0x63, 0x74, 0x21,
    ]

    // MARK: - Catalog identifiers (matching phonto)
    private static let categoryID    = "8C75F1C2-7E7E-4B5C-9C5C-50484F4E544F"
    private static let subcategoryID = "8C75F1C2-7E7E-4B5C-9C5C-535542434154"

    // MARK: - UserDefaults keys
    private static let onboardingKey = "hasShownAerialOnboarding"

    /// Notification posted (on main) when a lock-screen sync succeeds.
    /// Useful for triggering a one-time onboarding hint.
    static let didSyncNotification = Notification.Name("AerialCatalogDidSync")

    private override init() {
        super.init()
    }

    // ── Public API ────────────────────────────────────────────────────

    /// Fire-and-forget: syncs a video to the lock-screen catalog.
    /// Safe to call on any thread. Runs work on a background Task.
    /// @param videoURL Full file URL to the source .mp4 / .mov
    /// @param name     Human-readable name (filename without extension)
    @objc func syncLockscreen(videoURL: URL, name: String) {
        Task { [weak self] in
            await self?.gate.enqueue { [weak self] in
                await self?.performSync(videoURL: videoURL, name: name)
            }
        }
    }

    /// Returns true if the one-time onboarding hint has already been shown.
    @objc var hasShownOnboarding: Bool {
        UserDefaults.standard.bool(forKey: Self.onboardingKey)
    }

    /// Marks the onboarding hint as shown.
    @objc func markOnboardingShown() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
    }

    // ── OS version detection ──────────────────────────────────────────

    private var isTahoeOrLater: Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }

    // ── Encoder constants (matching phonto's transcode.rs) ────────────
    private let kAvgBitrate: Int32       = 15_000_000
    private let kExpectedFPS: Int32      = 60
    private let kMaxKeyFrameInterval: Int32 = 120
    private let kMaxKeyFrameDuration: Double = 2.0
    private let kTemporalLayerCount: Int32 = 2
    private let kBaseLayerFPS: Double    = 30.0

    // ── Core sync logic ───────────────────────────────────────────────

    private func performSync(videoURL: URL, name: String) async {
        if isTahoeOrLater {
            await syncTahoe(videoURL: videoURL, name: name)
        } else {
            syncSequoia(videoURL: videoURL, name: name)
        }
    }

    // ── Tahoe path (macOS 26+) ────────────────────────────────────────

    private func aerialsBaseURL() -> URL? {
        guard let home = NSHomeDirectoryForUser(NSUserName()) else { return nil }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials")
    }

    private func syncTahoe(videoURL: URL, name: String) async {
        guard let base = aerialsBaseURL() else {
            NSLog("[AerialCatalog] could not resolve home directory")
            return
        }

        let videosDir     = base.appendingPathComponent("videos")
        let thumbnailsDir = base.appendingPathComponent("thumbnails")
        let manifestPath  = base.appendingPathComponent("manifest/entries.json")

        let fm = FileManager.default

        // Ensure directories exist
        do {
            try fm.createDirectory(at: videosDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: manifestPath.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
        } catch {
            NSLog("[AerialCatalog] directory creation failed: %@", error.localizedDescription)
            return
        }

        guard fm.fileExists(atPath: manifestPath.path) else {
            NSLog("[AerialCatalog] entries.json not found — WallpaperAgent has never initialised")
            return
        }

        let canonicalPath = videoURL.resolvingSymlinksInPath().path
        let assetID       = Self.uuidv5(for: canonicalPath)

        let targetVideo = videosDir.appendingPathComponent("\(assetID).mov")
        let targetThumb = thumbnailsDir.appendingPathComponent("\(assetID).png")

        // ── Transcode to HEVC Main10 (matching phonto pipeline) ───────
        // NOTE: Each wallpaper pick creates a new transcode (~15Mbps HEVC).
        // Old entries accumulate in entries.json and aerials/ on disk.
        // A future "keep last N" eviction policy should remove stale UUIDs
        // from entries.json and delete their .mov/.png files. For now,
        // re-picking the same video path updates the same entry (UUIDv5
        // derived from path is stable), so only one entry per unique
        // source path accumulates regardless of how many times you pick it.
        NSLog("[AerialCatalog] transcoding → HEVC Main10 (2 temporal sub-layers)...")
        if !(await transcodeVideo(source: videoURL, dest: targetVideo)) {
            NSLog("[AerialCatalog] transcode failed for %@", videoURL.lastPathComponent)
            return
        }

        // ── Extract thumbnail (qlmanage, matching phonto) ─────────────
        NSLog("[AerialCatalog] extracting thumbnail...")
        if !qlmanageThumbnail(source: videoURL, dest: targetThumb) {
            NSLog("[AerialCatalog] thumbnail failed for %@", videoURL.lastPathComponent)
            try? fm.removeItem(at: targetVideo)
            return
        }
        NSLog("[AerialCatalog] thumbnail → %@", targetThumb.path)

        // ── Inject into entries.json ─────────────────────────────────
        let videoFileURL = fileURLString(for: targetVideo.path)
        let thumbFileURL = fileURLString(for: targetThumb.path)

        if !injectEntry(manifestPath: manifestPath,
                        assetID: assetID,
                        name: name,
                        videoURL: videoFileURL,
                        thumbURL: thumbFileURL) {
            NSLog("[AerialCatalog] entries.json injection failed for %@", name)
            return
        }

        // ── Kick the wallpaper service ────────────────────────────────
        kickTahoe()

        NSLog("[AerialCatalog] synced '%@' for lock screen (id %@)", name, assetID)

        await MainActor.run {
            NotificationCenter.default.post(name: Self.didSyncNotification, object: nil)
        }
    }

    // ── HEVC Main10 transcode (matching phonto's transcode.rs) ───────
    // Drives VTCompressionSession directly because AVAssetWriter's
    // outputSettings dictionary does not expose temporal sub-layer keys.
    // The lock-screen player needs exactly 2 temporal sub-layers in the
    // VPS for multi-cycle playback.

    private func transcodeVideo(source: URL, dest: URL) async -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        let asset = AVURLAsset(url: source)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            NSLog("[AerialCatalog] no video track in source")
            return false
        }
        let naturalSize = try? await videoTrack.load(.naturalSize)
        let width  = Int32(naturalSize?.width  ?? 1920)
        let height = Int32(naturalSize?.height ?? 1080)
        NSLog("[AerialCatalog] source: %dx%d", width, height)

        guard let reader = try? AVAssetReader(asset: asset) else {
            NSLog("[AerialCatalog] AVAssetReader init failed")
            return false
        }
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        reader.add(readerOutput)

        // Build session with callback+refcon in one shot
        let sink = TranscodeSink()
        let sinkPtr = Unmanaged.passUnretained(sink).toOpaque()

        var session: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width, height: height,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: kCFAllocatorDefault,
            outputCallback: transcodeCallback,
            refcon: sinkPtr,
            compressionSessionOut: &session
        )
        guard st == noErr, let sess = session else {
            NSLog("[AerialCatalog] VTCompressionSessionCreate: %d", st)
            return false
        }
        defer { VTCompressionSessionInvalidate(sess) }

        // Configure — every property must match phonto's transcode.rs
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_HEVC_Main10_AutoLevel as CFTypeRef)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: kAvgBitrate))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: kExpectedFPS))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: kMaxKeyFrameInterval))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: kMaxKeyFrameDuration))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanFalse!)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse!)

        // Temporal sub-layers — critical for multi-cycle lock-screen playback
        let ntlKey = "NumberOfTemporalLayers" as CFString
        let ntlSt = VTSessionSetProperty(sess, key: ntlKey,
                                         value: NSNumber(value: kTemporalLayerCount))
        if ntlSt != noErr {
            NSLog("[AerialCatalog] NumberOfTemporalLayers failed: %d", ntlSt)
            return false
        }
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_BaseLayerFrameRate,
                             value: NSNumber(value: kBaseLayerFPS))

        // Encode frames
        reader.startReading()
        var frameCount = 0
        while reader.status == .reading {
            guard let sample = readerOutput.copyNextSampleBuffer() else { break }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let dur = CMSampleBufferGetDuration(sample)
            let encSt = VTCompressionSessionEncodeFrame(sess,
                                                        imageBuffer: pixelBuffer,
                                                        presentationTimeStamp: pts,
                                                        duration: dur,
                                                        frameProperties: nil,
                                                        sourceFrameRefcon: nil,
                                                        infoFlagsOut: nil)
            if encSt != noErr {
                NSLog("[AerialCatalog] encode frame %d failed: %d", frameCount, encSt)
                return false
            }
            frameCount += 1
            if frameCount % 60 == 0 {
                NSLog("[AerialCatalog] encoding... %d frames", frameCount)
            }
        }

        if reader.status == .failed {
            NSLog("[AerialCatalog] AVAssetReader failed: %@", reader.error?.localizedDescription ?? "none")
            return false
        }

        VTCompressionSessionCompleteFrames(sess, untilPresentationTimeStamp: .invalid)

        if sink.firstError != noErr {
            NSLog("[AerialCatalog] encoder OSStatus %d", sink.firstError)
            return false
        }

        let samples = sink.samples
        if samples.isEmpty {
            NSLog("[AerialCatalog] encoder produced no samples")
            return false
        }
        NSLog("[AerialCatalog] encoded %d frames", frameCount)

        // Write .mov via AVAssetWriter (pass-through)
        guard let writer = try? AVAssetWriter(outputURL: dest, fileType: .mov) else {
            NSLog("[AerialCatalog] AVAssetWriter init failed")
            return false
        }
        guard let firstSample = samples.first,
              let fmtDesc = CMSampleBufferGetFormatDescription(firstSample) else {
            NSLog("[AerialCatalog] no format description")
            return false
        }
        let writerInput = AVAssetWriterInput(mediaType: .video,
                                             outputSettings: nil,
                                             sourceFormatHint: fmtDesc)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        writer.startWriting()
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(firstSample)
        writer.startSession(atSourceTime: firstPTS)

        var idx = 0
        while idx < samples.count {
            if writerInput.isReadyForMoreMediaData {
                if !writerInput.append(samples[idx]) {
                    NSLog("[AerialCatalog] appendSampleBuffer at %d: %@", idx,
                          writer.error?.localizedDescription ?? "none")
                    return false
                }
                idx += 1
            } else {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        writerInput.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { [writer] in
                writer.finishWriting { continuation.resume() }
            }
        }

        if writer.status == .failed {
            NSLog("[AerialCatalog] AVAssetWriter finishWriting: %@",
                  writer.error?.localizedDescription ?? "none")
            return false
        }

        NSLog("[AerialCatalog] wrote %d samples → %@", samples.count, dest.path)
        return true
    }

    // TranscodeSink collects encoded CMSampleBuffers from the VT callback
    private final class TranscodeSink {
        var samples: [CMSampleBuffer] = []
        var firstError: OSStatus = noErr
    }

    private let transcodeCallback: VTCompressionOutputCallback = {
        (refcon, _sourceFrameRefCon, status, _infoFlags, sampleBuffer) in
        guard let refcon = refcon else { return }
        let sink = Unmanaged<TranscodeSink>.fromOpaque(refcon).takeUnretainedValue()
        if status != noErr {
            if sink.firstError == noErr { sink.firstError = status }
            return
        }
        if let sb = sampleBuffer {
            sink.samples.append(sb)
        }
    }

    // ── qlmanage thumbnail extraction (matching phonto) ──────────────

    private func qlmanageThumbnail(source: URL, dest: URL) -> Bool {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("livewallpaper-thumb-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir,
                                                  withIntermediateDirectories: true)

        let task = Process()
        task.launchPath = "/usr/bin/qlmanage"
        task.arguments = ["-t", "-s", "640", "-o", tmpDir.path, source.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice

        do { try task.run(); task.waitUntilExit() }
        catch { NSLog("[AerialCatalog] qlmanage launch failed: %@", error.localizedDescription); return false }

        guard task.terminationStatus == 0 else {
            NSLog("[AerialCatalog] qlmanage exit status %d", task.terminationStatus)
            return false
        }

        // qlmanage OUTPUT FILENAME pattern (verified on macOS 26):
        //   source.mp4            → {outDir}/source.mp4.png
        //   source.mov            → {outDir}/source.mov.png
        //   source with space.mp4 → {outDir}/source with space.mp4.png
        // Always {sourceLastPathComponent}.png — never just {stem}.png
        let generated = tmpDir.appendingPathComponent("\(source.lastPathComponent).png")
        let fm = FileManager.default

        if !fm.fileExists(atPath: generated.path) {
            NSLog("[AerialCatalog] qlmanage produced no thumbnail at %@", generated.path)
            return false
        }

        try? fm.removeItem(at: dest)
        do { try fm.copyItem(at: generated, to: dest) }
        catch { NSLog("[AerialCatalog] thumbnail copy: %@", error.localizedDescription); return false
        }
        try? fm.removeItem(at: tmpDir)
        return true
    }

    // ── file:// URL builder ──────────────────────────────────────────

    private func fileURLString(for path: String) -> String {
        let encoded = path.replacingOccurrences(of: " ", with: "%20")
        return "file://\(encoded)"
    }

    // ── entries.json injection ───────────────────────────────────────

    private func injectEntry(manifestPath: URL,
                              assetID: String,
                              name: String,
                              videoURL: String,
                              thumbURL: String) -> Bool {

        let fm = FileManager.default

        // One-time backup
        let backupPath = manifestPath.path + ".livewallpaper-backup"
        if !fm.fileExists(atPath: backupPath) {
            try? fm.copyItem(atPath: manifestPath.path, toPath: backupPath)
        }

        guard let data = try? Data(contentsOf: manifestPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("[AerialCatalog] failed to parse entries.json")
            return false
        }

        var assets:     [[String: Any]]
        var categories: [[String: Any]]

        if let arr = root["assets"] as? [[String: Any]] {
            assets = arr
        } else {
            assets = []
        }

        if let arr = root["categories"] as? [[String: Any]] {
            categories = arr
        } else {
            categories = []
        }

        // Build asset entry
        let shotID = "LWP_\(assetID.prefix(8))"
        let assetEntry: [String: Any] = [
            "id": assetID,
            "categories": [Self.categoryID],
            "subcategories": [Self.subcategoryID],
            "previewImage": thumbURL,
            "accessibilityLabel": name,
            "localizedNameKey": name,
            "includeInShuffle": false,
            "pointsOfInterest": [String: Any](),
            "preferredOrder": 0,
            "shotID": shotID,
            "showInTopLevel": true,
            "url-4K-SDR-240FPS": videoURL,
        ]

        // Upsert asset
        if let idx = assets.firstIndex(where: { ($0["id"] as? String) == assetID }) {
            assets[idx] = assetEntry
        } else {
            assets.insert(assetEntry, at: 0)
        }

        // Upsert category
        upsertCategory(&categories, repAssetID: assetID, previewURL: thumbURL)

        root["assets"]     = assets
        root["categories"] = categories

        guard let outData = try? JSONSerialization.data(withJSONObject: root,
                                                        options: .prettyPrinted) else {
            NSLog("[AerialCatalog] JSON serialization failed")
            return false
        }

        do {
            try outData.write(to: manifestPath)
            return true
        } catch {
            NSLog("[AerialCatalog] writing entries.json: %@", error.localizedDescription)
            return false
        }
    }

    private func upsertCategory(_ categories: inout [[String: Any]],
                                 repAssetID: String,
                                 previewURL: String) {

        let subcategory: [String: Any] = [
            "id": Self.subcategoryID,
            "representativeAssetID": repAssetID,
            "previewImage": previewURL,
            "localizedDescriptionKey": "LiveWallpaper",
            "localizedNameKey": "LiveWallpaper",
            "preferredOrder": 0,
        ]

        let category: [String: Any] = [
            "id": Self.categoryID,
            "representativeAssetID": repAssetID,
            "previewImage": previewURL,
            "subcategories": [subcategory],
            "localizedDescriptionKey": "LiveWallpaper",
            "localizedNameKey": "LiveWallpaper",
            "preferredOrder": -1,  // before Apple's Landscapes
        ]

        if let idx = categories.firstIndex(where: { ($0["id"] as? String) == Self.categoryID }) {
            categories[idx] = category
        } else {
            categories.append(category)
        }
    }

    // ── Kick Tahoe wallpaper services ────────────────────────────────

    private func kickTahoe() {
        let services = [
            "Wallpaper",
            "WallpaperAgent",
            "WallpaperAerialsExtension",
            "WallpaperImageExtension",
            "WallpaperLegacyExtension",
        ]
        for svc in services {
            let task = Process()
            task.launchPath = "/usr/bin/killall"
            task.arguments = [svc]
            task.standardOutput = FileHandle.nullDevice
            task.standardError  = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }

    // ── Sequoia path (macOS 14-15) — stubbed ─────────────────────────

    /// TODO: Implement root-level aerial catalog injection for
    /// /Library/Application Support/com.apple.idleassetsd/Customer/
    /// using a privileged helper installed via SMAppService / SMJobBless.
    /// For now, lock-screen sync is skipped on macOS < 26.
    private func syncSequoia(videoURL: URL, name: String) {
        NSLog("[AerialCatalog] lock-screen sync skipped on macOS < 26: "
              + "privileged helper required for idleassetsd catalog. %@", name)
    }

    // ── UUIDv5 generator ─────────────────────────────────────────────

    static func uuidv5(for input: String) -> String {
        let inputData = Array(input.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))

        var ctx = CC_SHA1_CTX()
        CC_SHA1_Init(&ctx)
        CC_SHA1_Update(&ctx, namespaceBytes, CC_LONG(namespaceBytes.count))
        CC_SHA1_Update(&ctx, inputData, CC_LONG(inputData.count))
        CC_SHA1_Final(&hash, &ctx)

        // Set UUID version 5
        hash[6] = (hash[6] & 0x0F) | 0x50
        // Set UUID variant 10xx
        hash[8] = (hash[8] & 0x3F) | 0x80

        return String(format: "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                      hash[0],  hash[1],  hash[2],  hash[3],
                      hash[4],  hash[5],  hash[6],  hash[7],
                      hash[8],  hash[9],  hash[10], hash[11],
                      hash[12], hash[13], hash[14], hash[15])
    }
}
