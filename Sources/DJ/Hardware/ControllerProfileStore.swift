import Foundation
import GRDB

/// Persistence for controller profiles (§15's `controller_profile` /
/// `midi_mapping` / `midi_binding`, FR-HW-2).
///
/// Bindings are stored one row per control, in the shape §15 specifies, rather
/// than as a JSON blob: a mapping is data a user may one day want to query,
/// diff or repair, and a blob makes all three impossible. The JSON form exists
/// too — but as the *interchange* format (`export`/`import`), which is what
/// FR-HW-2's "importable/exportable" means and what lets a community share
/// profiles without the app hosting anything.
public struct ControllerProfileStore: Sendable {

    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    /// Save a profile and its bindings in **one transaction** — a half-written
    /// map is worse than none, because the controls that did save would work
    /// and the rest would silently not (NFR-REL-1).
    public func save(_ profile: ControllerProfile, syncID: String, active: Bool = true) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO controller_profile (syncID, name, vendor, midiEndpointName, active, createdAt)
                VALUES (?, ?, ?, ?, ?, datetime('now'))
                ON CONFLICT(syncID) DO UPDATE SET
                    name = excluded.name,
                    vendor = excluded.vendor,
                    midiEndpointName = excluded.midiEndpointName,
                    active = excluded.active
                """, arguments: [syncID, profile.name, profile.vendor, profile.endpointName, active])
            let profileID = try Int64.fetchOne(
                db, sql: "SELECT id FROM controller_profile WHERE syncID = ?", arguments: [syncID])
            guard let profileID else { return }

            // Replace the mapping wholesale: re-saving a profile is what
            // happens after every learn, and merging would leave stale
            // bindings for controls the user has since re-bound.
            try db.execute(sql: "DELETE FROM midi_mapping WHERE profileID = ?",
                           arguments: [profileID])
            try db.execute(sql: """
                INSERT INTO midi_mapping (profileID, name, updatedAt)
                VALUES (?, 'default', datetime('now'))
                """, arguments: [profileID])
            let mappingID = db.lastInsertedRowID

            for binding in profile.bindings {
                try db.execute(sql: """
                    INSERT INTO midi_binding
                        (mappingID, target, messageType, channel, number, mode, minValue, maxValue, invert, takeover)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [mappingID,
                                     binding.action.target,
                                     binding.address.type.rawValue,
                                     binding.address.channel,
                                     binding.address.number,
                                     binding.transform.mode.rawValue,
                                     Int(binding.transform.minimum * 127),
                                     Int(binding.transform.maximum * 127),
                                     binding.transform.invert,
                                     binding.takeover.rawValue])
            }
        }
    }

    /// The active profile, or nil when the user has never mapped a controller.
    public func activeProfile() throws -> ControllerProfile? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, name, vendor, midiEndpointName FROM controller_profile
                WHERE active = 1 ORDER BY id DESC LIMIT 1
                """) else { return nil }
            let profileID: Int64 = row["id"]
            var profile = ControllerProfile(name: row["name"],
                                            vendor: row["vendor"],
                                            endpointName: row["midiEndpointName"])
            let bindingRows = try Row.fetchAll(db, sql: """
                SELECT b.target, b.messageType, b.channel, b.number, b.mode,
                       b.minValue, b.maxValue, b.invert, b.takeover
                FROM midi_binding b
                JOIN midi_mapping m ON m.id = b.mappingID
                WHERE m.profileID = ?
                """, arguments: [profileID])
            for row in bindingRows {
                // An unparseable target is **skipped, not defaulted**: a
                // mapping written by a newer version must never silently bind
                // a user's crossfader to something else.
                guard let action = EngineAction.parse(target: row["target"]),
                      let type = MidiAddress.MessageType(rawValue: row["messageType"]),
                      let mode = ValueTransform.Mode(rawValue: row["mode"]),
                      let takeover = Takeover(rawValue: row["takeover"]) else { continue }
                let minimum = Float(row["minValue"] as Int) / 127
                let maximum = Float(row["maxValue"] as Int) / 127
                profile.bindings.append(MidiBinding(
                    address: MidiAddress(type: type, channel: row["channel"], number: row["number"]),
                    action: action,
                    transform: ValueTransform(mode: mode, minimum: minimum, maximum: maximum,
                                              invert: row["invert"]),
                    takeover: takeover))
            }
            return profile
        }
    }

    // MARK: - Interchange (FR-HW-2)

    /// Export as JSON for the Files app. Pretty-printed and key-sorted so a
    /// shared profile diffs cleanly and a human can read it.
    public static func exportData(_ profile: ControllerProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }

    public static func importProfile(from data: Data) throws -> ControllerProfile {
        try JSONDecoder().decode(ControllerProfile.self, from: data)
    }
}
