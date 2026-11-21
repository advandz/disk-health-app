//
//  DiskWatcher.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import DiskArbitration
import Foundation

/// Watches DiskArbitration for drives being attached, removed, mounted or
/// unmounted, and calls back (debounced) so the drive list stays current.
final class DiskWatcher {
    private let session: DASession
    private let handler: @MainActor () -> Void
    private var pending: DispatchWorkItem?

    init?(handler: @escaping @MainActor () -> Void) {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        self.session = session
        self.handler = handler

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { _, ctx in
            guard let ctx else { return }
            Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue().fire()
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { _, ctx in
            guard let ctx else { return }
            Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue().fire()
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, kDADiskDescriptionWatchVolumePath.takeUnretainedValue(), { _, _, ctx in
            guard let ctx else { return }
            Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue().fire()
        }, context)
        DASessionSetDispatchQueue(session, .main)
    }

    deinit {
        DASessionSetDispatchQueue(session, nil)
    }

    private func fire() {
        pending?.cancel()
        let work = DispatchWorkItem { [handler] in
            MainActor.assumeIsolated { handler() }
        }
        pending = work
        // The session reports every existing disk on registration; debounce bursts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
