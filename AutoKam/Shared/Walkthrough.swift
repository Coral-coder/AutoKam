import SwiftUI

struct WalkthroughPage {
    var symbol: String
    var title: String
    var lines: [String]
}

enum Walkthrough {
    static let pages: [WalkthroughPage] = [
        WalkthroughPage(symbol: "video.badge.checkmark", title: "Welcome to AutoKam", lines: [
            "The iPhone is the camera. The Mac is the receiver: every take is saved straight into a folder on it while you record. No more AirDropping huge files.",
            "Mark the good takes with a gesture, and the Good Takes folder ends up holding only the keepers.",
        ]),
        WalkthroughPage(symbol: "desktopcomputer", title: "1 · Open AutoKam on the Mac", lines: [
            "Leave it open while you film. The iPhone finds it by itself, on the same Wi‑Fi or over a direct Wi‑Fi link.",
            "The Mac shows a live view and has Record, Retake, Keep and Cut buttons if someone's helping.",
            "The dot at the top of the iPhone turns green and shows the Mac's name when it's connected.",
        ]),
        WalkthroughPage(symbol: "camera.viewfinder", title: "2 · Set up the shot", lines: [
            "Choose the shape at the top: Auto, 9:16 (portrait) or 16:9 (landscape). The screen turns to match.",
            "Focus: the box shows where the camera is focusing. Green means it's on your face, yellow means it's adjusting.",
            "Tap the screen to focus on a spot. Hold your finger down to go back to automatic.",
            "Showing a product: hold it up in front of your open hand for a moment. Focus jumps to it (blue box, OBJECT) and gestures are ignored while your hand is up. Lower your hand out of frame and focus goes back to your face.",
            "Level: the line across the middle follows the real horizon. Tilt until it turns green and says LEVEL. It works in portrait and landscape.",
        ]),
        WalkthroughPage(symbol: "mic.fill", title: "3 · Sound", lines: [
            "Plug in the external mic receiver. The chip at the top shows which mic is recording, in green when it's the external one.",
            "The meter on the right shows left and right levels as you talk.",
            "A small yellow note appears if the external mic isn't connected, or if a take starts and no sound is coming in. Tap it to hide it for a couple of minutes.",
        ]),
        WalkthroughPage(symbol: "hand.raised.fill", title: "4 · Hand gestures — in the corner", lines: [
            "A box is drawn in the top corner of the camera screen. Make the gesture with one hand inside that box and hold it still for a moment. Hands anywhere else — holding a product or a mirror, talking — are ignored.",
            "✋  Open hand: start recording. While recording it means \"goofed\": that take is tossed and the same segment counts in again.",
            "✊  Fist: cut. This take is kept, then the next segment counts in, so there's time to drop your hand.",
            "👍  Thumbs up: keep this take and stop.",
            "✌️  Peace sign: stop without keeping.",
            "The box turns green when it sees your hand, a ring fills while the gesture is read, then a ✓ and a sound confirm it. Settings → Gestures: which corner, Both-hands mode, sensitivity. Tap the gesture bar to pause gestures.",
        ]),
        WalkthroughPage(symbol: "film.stack", title: "5 · Segments and takes", lines: [
            "A video is built from segments, and each segment can take a few tries.",
            "Seg 01 · Take 01, goofed ✋ → Seg 01 · Take 02, nailed it ✊ → Seg 02 · Take 01 … last segment done 👍",
            "Files are named the same way, \"Seg 02 - Take 03\". The arrows by the segment number step it by hand.",
        ]),
        WalkthroughPage(symbol: "scissors", title: "6 · Editing", lines: [
            "On the Mac: Movies → AutoKam → your session.",
            "Good Takes holds only the kept takes, in segment order, with the gesture cut off the end. Import that folder and go.",
            "All Takes keeps everything, just in case. New Session on the Mac starts a fresh folder.",
        ]),
    ]
}

struct WalkthroughView: View {
    var onDone: () -> Void
    @State private var page = 0

    var body: some View {
        #if os(iOS)
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Walkthrough.pages.indices, id: \.self) { i in
                    ScrollView {
                        WalkthroughPageView(page: Walkthrough.pages[i])
                            .padding(.horizontal, 28)
                            .padding(.top, 48)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            HStack {
                Button("Skip") { onDone() }
                    .foregroundStyle(.secondary)
                Spacer()
                Button(page == Walkthrough.pages.count - 1 ? "Start filming" : "Next") {
                    if page == Walkthrough.pages.count - 1 {
                        onDone()
                    } else {
                        withAnimation { page += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }
        .background(Color(.systemBackground))
        #else
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(Walkthrough.pages.indices, id: \.self) { i in
                        WalkthroughPageView(page: Walkthrough.pages[i])
                    }
                }
                .padding(28)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 640)
        #endif
    }
}

private struct WalkthroughPageView: View {
    let page: WalkthroughPage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: page.symbol)
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text(page.title)
                .font(.title2.weight(.bold))
            ForEach(page.lines, id: \.self) { line in
                Text(line)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
