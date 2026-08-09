import Foundation
import SkipFuse
import SwiftUI
import MuonCore

/// A logger for the MuonSkip module.
let logger: Logger = Logger(subsystem: "me.pecheny.muonplayer", category: "MuonSkip")

/// The shared top-level view for the app, bridged to Kotlin as the activity's content.
///
/// It shows `MuonCore.RootView` — the same screens the iOS app runs, over the same
/// object graph. The Android-only diagnostic harness that used to live here is now
/// reachable from Settings instead of owning the root.
/* SKIP @bridge */public struct MuonSkipRootView : View {
    /* SKIP @bridge */public init() {
    }

    public var body: some View {
        RootView()
    }
}

/// Global application delegate functions.
///
/// These functions can update a shared observable object to communicate app state changes to interested views.
/* SKIP @bridge */public final class MuonSkipAppDelegate : Sendable {
    /* SKIP @bridge */public static let shared = MuonSkipAppDelegate()

    private init() {
    }

    /* SKIP @bridge */public func onInit() {
        logger.debug("onInit")
    }

    /* SKIP @bridge */public func onLaunch() {
        logger.debug("onLaunch")
    }

    /* SKIP @bridge */public func onResume() {
        logger.debug("onResume")
    }

    /* SKIP @bridge */public func onPause() {
        logger.debug("onPause")
    }

    /* SKIP @bridge */public func onStop() {
        logger.debug("onStop")
    }

    /* SKIP @bridge */public func onDestroy() {
        logger.debug("onDestroy")
    }

    /* SKIP @bridge */public func onLowMemory() {
        logger.debug("onLowMemory")
    }
}
