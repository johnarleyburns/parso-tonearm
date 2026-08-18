import SwiftUI
import TonearmCore
#if canImport(UIKit)
import UIKit
#endif

/// Launch splash: spring fade-in, 1.5 s hold, 0.35 s ease-out handoff via
/// `isPresented`. The foreground is the periodic-table tile for Pt (Platinum),
/// mirroring `scripts/make_icon.py`; the field is the library gradient with
/// the icon's brass radial glow.
struct AnimatedSplashView: View {
    @Binding var isPresented: Bool

    @State private var opacity: Double = 0
    @State private var tileScale: CGFloat = 0.7

    var body: some View {
        ZStack {
            splashImage
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            Color.black.opacity(0.35)

            RadialGradient(colors: [Palette.brass.opacity(0.20), .clear],
                           center: UnitPoint(x: 0.28, y: 0.08),
                           startRadius: 0, endRadius: 640)
        }
        .ignoresSafeArea()
        .overlay {
            PeriodicTileView(
                atomicNumber: "78",
                symbol: "Pt",
                name: "Platterhead",
                atomicWeight: "195.08"
            )
            .scaleEffect(tileScale)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Platterhead")
        }
        .opacity(opacity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                opacity = 1
                tileScale = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.35)) {
                    isPresented = false
                }
            }
        }
    }

    /// `splash_screen.jpg` is intentionally a loose bundle resource (rather
    /// than an asset-catalog rendition) so the same portrait artwork can be
    /// used by the system launch screen. Resolve it from the bundle explicitly;
    /// `Image("splash_screen")` only reliably finds asset-catalog names on some
    /// iOS releases and otherwise falls through to the stretched first frame.
    private var splashImage: Image {
        #if canImport(UIKit)
        if let url = Bundle.main.url(forResource: "splash_screen", withExtension: "jpg"),
           let image = UIImage(contentsOfFile: url.path) {
            return Image(uiImage: image)
        }
        #endif
        return Image("SplashScreen")
    }
}

/// Periodic-table element tile matching the app icon: atomic number top-left,
/// large element symbol, app name, and atomic weight on a dark field with a
/// brass radial glow.
struct PeriodicTileView: View {
    let atomicNumber: String
    let symbol: String
    let name: String
    let atomicWeight: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(atomicNumber)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Palette.ink)
                Spacer()
            }

            Spacer(minLength: 0)

            Text(symbol)
                .font(.system(size: 88, weight: .bold))
                .foregroundStyle(Palette.ink)

            Spacer(minLength: 0)

            Text(name)
                .font(.system(size: 17))
                .foregroundStyle(Palette.ink)

            Text(atomicWeight)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
                .padding(.top, 3)
        }
        .padding(22)
        .frame(width: 224, height: 224)
        .background {
            Rectangle()
                .fill(LinearGradient(colors: [Color(hex: 0x12141A).opacity(0.55), Color(hex: 0x0A0B0D).opacity(0.55)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    RadialGradient(colors: [Palette.brass.opacity(0.30), .clear],
                                   center: UnitPoint(x: 0.28, y: 0.08),
                                   startRadius: 0, endRadius: 250)
                }
                .clipShape(Rectangle())
                .shadow(color: Color.black.opacity(0.45), radius: 26, y: 14)
        }
        .overlay {
            Rectangle()
                .strokeBorder(Palette.brass.opacity(0.32), lineWidth: 1)
        }
    }
}

#Preview {
    AnimatedSplashView(isPresented: .constant(true))
}
