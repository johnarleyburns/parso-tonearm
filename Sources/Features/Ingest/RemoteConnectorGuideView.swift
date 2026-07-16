import SwiftUI
import TonearmCore

struct RemoteConnectorGuideView: View {
    let guide: RemoteConnectorGuide
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(guide.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.system(size: 13, weight: .bold))
                            Text(section.body)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(18)
            }
            .foregroundStyle(Palette.ink)
            .background(Palette.sourcesBackground.ignoresSafeArea())
            .navigationTitle(guide.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
