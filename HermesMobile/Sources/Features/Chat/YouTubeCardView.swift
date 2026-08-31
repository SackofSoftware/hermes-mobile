import HermesKit
import SwiftUI

/// A tappable card for a YouTube link in an assistant reply: thumbnail, play badge, and
/// the real title (fetched keylessly from YouTube's oEmbed endpoint, best-effort).
///
/// Deliberately NOT an embedded player — that means a WKWebView running YouTube's iframe,
/// a heavyweight dependency for a chat transcript. A tap hands off to the YouTube app,
/// which does playback better than any embed would.
struct YouTubeCardView: View {
  let link: YouTubeLink

  @State private var title: String?
  @Environment(\.openURL) private var openURL

  var body: some View {
    Button {
      openURL(link.watchURL)
    } label: {
      VStack(alignment: .leading, spacing: 0) {
        ZStack {
          AsyncImage(url: link.thumbnailURL) { phase in
            switch phase {
            case let .success(image):
              image.resizable().aspectRatio(contentMode: .fill)
            default:
              // hqdefault virtually never fails; if it does, keep the 16:9 slot so
              // the card doesn't collapse mid-scroll.
              Rectangle().fill(.quaternary)
            }
          }
          .aspectRatio(16 / 9, contentMode: .fit)
          .clipped()
          Image(systemName: "play.circle.fill")
            .font(.system(size: 44))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.6))
        }
        HStack(spacing: 8) {
          Image(systemName: "play.rectangle.fill")
            .foregroundStyle(.red)
          Text(title ?? "YouTube")
            .font(.callout.weight(.medium))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 0)
          Image(systemName: "arrow.up.forward")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
      }
      .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
      .clipShape(.rect(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("YouTube video: \(title ?? "untitled")")
    .accessibilityHint("Opens in YouTube")
    .task {
      guard title == nil else { return }
      // Best-effort title. Failure leaves the generic label — never an error state.
      if let (data, _) = try? await URLSession.shared.data(from: link.oembedURL),
         let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let fetched = payload["title"] as? String, !fetched.isEmpty {
        title = fetched
      }
    }
  }
}
