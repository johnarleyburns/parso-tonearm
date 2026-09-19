import SwiftUI
import TonearmCore

/// Owner-editable title/artist correction — same tier as "Change Artwork"
/// (real report: an imported file's own embedded tags were wrong, with no
/// way to fix it short of re-tagging the file outside the app).
struct EditTrackMetadataSheet: View {
    let row: TrackRow
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var artist: String
    @State private var isSaving = false

    init(row: TrackRow) {
        self.row = row
        _title = State(initialValue: row.track.title)
        _artist = State(initialValue: row.artist?.name ?? row.album?.artist ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("editMetadata.title")
                }
                Section("Artist") {
                    TextField("Artist", text: $artist)
                        .accessibilityIdentifier("editMetadata.artist")
                }
            }
            .navigationTitle("Edit Track Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            _ = await appState.editTrackMetadata(
                                row: row, title: title, artistName: artist)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                    .accessibilityIdentifier("editMetadata.save")
                }
            }
        }
    }
}
