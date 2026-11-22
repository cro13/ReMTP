import Foundation

extension TransferCenter {
    /// Active jobs copying from `source` into `destination`.
    func activeJobs(from source: PaneLocation, to destination: PaneLocation) -> [QueuedTransfer] {
        jobs.filter { $0.isActive && $0.destinationFolder.isSameFolder(as: destination) && $0.sourceFolder.isSameFolder(as: source) }
    }

    /// Those of `items` (in `source`) that an active job is already copying into `destination`, still to come
    /// or already copied (the job isn't over yet). Copying them again would only end in conflicts.
    func inFlight(_ items: [FileItem], from source: PaneLocation, to destination: PaneLocation) -> [FileItem] {
        let route = activeJobs(from: source, to: destination)
        guard !route.isEmpty else { return [] }
        return items.filter { item in
            route.contains { $0.sources[item.compareKey] != nil || $0.doneKeys.contains(item.compareKey) }
        }
    }

    func isWriting(in location: PaneLocation) -> Bool {
        jobs.contains {
            ($0.state == .starting || $0.state == .running) && !$0.isPromise
                && location.relativeComponents(to: $0.destinationFolder) != nil
        }
    }

    func paneArrivals(in location: PaneLocation, existing: [String: FileItem]) -> ArrivalInfo? {
        var keys: Set<String> = []
        var route: PaneLocation?
        for job in jobs where job.isActive && !job.isPromise && job.destinationFolder.isSameFolder(as: location) {
            if let progress = job.progress, progress.filesDone == progress.filesTotal { continue }
            route = job.destinationFolder
            for key in job.sources.keys where existing[key] == nil && !job.doneKeys.contains(key) {
                keys.insert(key)
            }
        }
        guard let route, !keys.isEmpty else { return nil }
        if var current = arrivals(in: route, existing: existing), let name = current.currentName,
           keys.contains(FileItem.compareKey(name)) {
            current.remaining = keys.count - 1
            return current
        }
        return ArrivalInfo(currentName: nil, currentSize: 0, fraction: 0, remaining: keys.count)
    }
}
