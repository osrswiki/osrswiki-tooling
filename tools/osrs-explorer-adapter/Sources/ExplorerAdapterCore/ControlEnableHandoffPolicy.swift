import Foundation

public enum ControlEnableHandoffPolicy {
    public static func candidateProcessIdentifiers(
        snapshot: FocusInvariantSnapshot,
        excluding excluded: Set<Int32>
    ) -> [Int32] {
        var seen = Set<Int32>()
        return snapshot.orderedRestorableWindowProcessIdentifiers.compactMap { processIdentifier in
            guard processIdentifier > 0,
                  !excluded.contains(processIdentifier),
                  seen.insert(processIdentifier).inserted else {
                return nil
            }
            return processIdentifier
        }
    }
}
