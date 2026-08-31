import ComposableArchitecture
import HermesKit
import SwiftUI

/// A file the agent sent, rendered under its message.
///
/// Loads metadata first, then bytes only when it's an image small enough to draw. Anything
/// else — a PDF, a video, a large image — stays a compact card showing name, type and
/// size. That ordering is the point: fetching a 2 GB video's bytes to discover it's a
/// video would be exactly the mistake the streaming server side was built to avoid.
struct MediaAttachmentView: View {
  let marker: MediaMarker
  let connection: ServerConnection

  @State private var item: MediaItem?
  @State private var imageData: Data?
  @State private var failure: String?
  @State private var isLoading = true

  @Dependency(\.hermesREST) private var rest

  /// Images at or under this are drawn inline; larger ones stay a card so a huge photo
  /// can't stall the transcript.
  private static let inlineImageLimit = 12 * 1024 * 1024

  var body: some View {
    Group {
      if let failure {
        card(icon: "exclamationmark.triangle", title: "Couldn't load attachment", subtitle: failure)
      } else if let data = imageData, let image = UIImage(data: data) {
        VStack(alignment: .leading, spacing: 4) {
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 12))
          if let caption = displayCaption {
            Text(caption).font(.caption).foregroundStyle(.secondary)
          }
        }
      } else if let item {
        card(
          icon: icon(for: item.contentType),
          title: item.name,
          subtitle: "\(Self.sizeLabel(item.sizeBytes)) · \(item.contentType)"
        )
      } else if isLoading {
        card(icon: "arrow.down.circle", title: "Loading attachment…", subtitle: nil)
      }
    }
    .task { await load() }
  }

  private var displayCaption: String? {
    let c = marker.caption.trimmingCharacters(in: .whitespaces)
    // The agent falls back to the filename as alt text; repeating it under the image adds
    // nothing, so only show a caption that says something the image doesn't.
    if c.isEmpty || c == item?.name { return nil }
    return c
  }

  private func load() async {
    guard item == nil, failure == nil else { return }
    do {
      let meta = try await rest.mediaItem(connection, marker.id)
      item = meta
      isLoading = false
      guard meta.isImage, meta.sizeBytes <= Self.inlineImageLimit else { return }
      imageData = try? await rest.mediaData(connection, marker.id)
    } catch let error as RESTError {
      // A 410 means the file moved or stopped being servable since the agent sent it —
      // worth saying plainly rather than showing an empty box.
      failure = error.message
      isLoading = false
    } catch {
      failure = "Unavailable"
      isLoading = false
    }
  }

  private func card(icon: String, title: String, subtitle: String?) -> some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.callout).lineLimit(1).truncationMode(.middle)
        if let subtitle {
          Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
  }

  private func icon(for contentType: String) -> String {
    if contentType.hasPrefix("video/") { return "play.rectangle" }
    if contentType.hasPrefix("audio/") { return "waveform" }
    if contentType.hasPrefix("image/") { return "photo" }
    if contentType.contains("pdf") { return "doc.richtext" }
    if contentType.hasPrefix("text/") || contentType.contains("json") { return "doc.text" }
    return "doc"
  }

  static func sizeLabel(_ bytes: Int) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: Int64(bytes))
  }
}
