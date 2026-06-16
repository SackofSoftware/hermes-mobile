import Foundation

/// A file the user has attached to the next message (#8). iOS shares no filesystem with
/// the agent, so the bytes are uploaded on submit via `image.attach_bytes` / `pdf.attach` /
/// `file.attach` (chosen by `kind`). Held in `ChatFeature.State` until the message is sent.
public struct ComposerAttachment: Equatable, Identifiable, Sendable {
  /// Which gateway upload method handles this attachment.
  public enum Kind: Equatable, Sendable {
    case image  // → image.attach_bytes (vision)
    case pdf    // → pdf.attach (rendered to page images)
    case file   // → file.attach (readable artifact, returns an @file: ref)
  }

  /// Per-attachment upload progress, surfaced as a chip indicator.
  public enum UploadState: Equatable, Sendable {
    case pending
    case uploading
    /// Succeeded. `ref` is the `@file:` reference for `.file` uploads (nil for image/pdf,
    /// which the agent picks up from session state).
    case uploaded(ref: String?)
    case failed(String)
  }

  public let id: UUID
  public var kind: Kind
  public var filename: String
  public var mimeType: String
  public var data: Data
  public var uploadState: UploadState

  public init(
    id: UUID,
    kind: Kind,
    filename: String,
    mimeType: String,
    data: Data,
    uploadState: UploadState = .pending
  ) {
    self.id = id
    self.kind = kind
    self.filename = filename
    self.mimeType = mimeType
    self.data = data
    self.uploadState = uploadState
  }

  /// `data:<mime>;base64,<…>` URL used by `pdf.attach` / `file.attach` uploads.
  public var dataURL: String {
    "data:\(mimeType);base64,\(data.base64EncodedString())"
  }

  /// Raw base64 (no `data:` prefix) used by `image.attach_bytes`'s `content_base64`.
  public var base64: String {
    data.base64EncodedString()
  }
}
