// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

import SwiftUI

// Native Mac app (docs/plans/native-mac-app-plan.md §2b): `UIImage`/
// `UIColor` are used throughout as the concrete artwork/tint type. One
// shared typealias lets every call site stay platform-agnostic instead of
// each file growing its own `#if os(macOS)` branch.
#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
#endif

public extension Image {
    /// `Image(uiImage:)` on iOS/iPadOS, `Image(nsImage:)` on macOS — SwiftUI's
    /// own initializer name differs by platform even though the semantics
    /// (wrap a fully-decoded platform image) are identical.
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

public extension PlatformImage {
    /// `UIImage.cgImage` is a plain property; `NSImage` has no equivalent
    /// property — only `cgImage(forProposedRect:context:hints:)`, a method
    /// that needs an in/out proposed-rect argument. This normalizes both to
    /// one accessor.
    var tonearmCGImage: CGImage? {
        #if os(macOS)
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return cgImage
        #endif
    }

    /// `UIImage.scale` (the Retina backing-store multiplier) has no
    /// `NSImage` equivalent — `NSImage.size` already represents a simple
    /// bitmap-backed image's true point size (this app's artwork is always
    /// decoded from JPEG/PNG `Data`, never a multi-representation asset), so
    /// macOS treats scale as 1 (native Mac app,
    /// docs/plans/native-mac-app-plan.md §2b).
    var platformScale: CGFloat {
        #if os(macOS)
        1
        #else
        scale
        #endif
    }
}

public extension View {
    /// `.navigationBarTitleDisplayMode(.inline)` is a UIKit-flavored SwiftUI
    /// API that doesn't exist on macOS (there is no "large vs. inline nav
    /// bar title" concept in `NSToolbar` chrome — the title just sits in the
    /// unified title bar). A no-op on macOS is the correct behavior, not a
    /// missing feature to work around.
    @ViewBuilder
    func compactNavigationTitle() -> some View {
        #if os(macOS)
        self
        #else
        self.navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// `.textInputAutocapitalization(_:)` has no macOS equivalent — there is
    /// no on-screen keyboard to auto-capitalize, so a no-op is correct there
    /// rather than a missing feature. `TextInputAutocapitalization` itself
    /// isn't even declared on macOS, so this takes the app's own
    /// cross-platform `PlatformAutocapitalization` instead of that type.
    @ViewBuilder
    func platformAutocapitalization(_ autocapitalization: PlatformAutocapitalization) -> some View {
        #if os(macOS)
        self
        #else
        self.textInputAutocapitalization(autocapitalization.uiKit)
        #endif
    }
}

public enum PlatformAutocapitalization {
    case never, words, sentences, characters

    #if !os(macOS)
    var uiKit: TextInputAutocapitalization {
        switch self {
        case .never: return .never
        case .words: return .words
        case .sentences: return .sentences
        case .characters: return .characters
        }
    }
    #endif
}
