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

import Foundation

/// Thin @objc bridge so Objective‑C++ code (WallpaperEngine.mm) can
/// fire‑and‑forget a lock‑screen catalog sync without importing the
/// generated Swift header everywhere.
@objc(AerialCatalogBridge)
final class AerialCatalogBridge: NSObject {

    /// Fire‑and‑forget lock‑screen sync for the given video path.
    /// Dispatches to AerialCatalogManager on a background task.
    /// @param videoPath Full absolute path to the source .mp4 / .mov
    @objc static func syncVideo(_ videoPath: String) {
        let url = URL(fileURLWithPath: videoPath)
        let name = url.deletingPathExtension().lastPathComponent
        AerialCatalogManager.shared.syncLockscreen(videoURL: url, name: name)
    }

    /// Returns true if the one‑time onboarding alert has been shown.
    @objc static var hasShownOnboarding: Bool {
        AerialCatalogManager.shared.hasShownOnboarding
    }

    /// Marks the onboarding hint as shown.
    @objc static func markOnboardingShown() {
        AerialCatalogManager.shared.markOnboardingShown()
    }
}
