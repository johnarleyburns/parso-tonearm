import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// "Change Artwork": on iPhone the Photos picker; on Mac an Open panel for
/// image files (its sidebar still reaches the Photos library), since Mac
/// artwork usually lives in Finder rather than Photos. `onPick` receives the
/// image bytes either way.
struct ArtworkImagePicker: ViewModifier {
    @Binding var isPresented: Bool
    let onPick: @MainActor (Data) async -> Void
    #if os(iOS)
    @State private var item: PhotosPickerItem?
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .photosPicker(isPresented: $isPresented, selection: $item, matching: .images)
            .onChange(of: item) { _, picked in
                guard let picked else { return }
                Task {
                    if let data = try? await picked.loadTransferable(type: Data.self) {
                        await onPick(data)
                    }
                    item = nil
                }
            }
        #else
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                let data = try? Data(contentsOf: url)
                if accessed { url.stopAccessingSecurityScopedResource() }
                guard let data else { return }
                Task { await onPick(data) }
            }
        #endif
    }
}

extension View {
    func artworkImagePicker(isPresented: Binding<Bool>,
                            onPick: @escaping @MainActor (Data) async -> Void) -> some View {
        modifier(ArtworkImagePicker(isPresented: isPresented, onPick: onPick))
    }
}
