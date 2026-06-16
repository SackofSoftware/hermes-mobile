import ComposableArchitecture
import DependenciesMacros
import Foundation

/// A file the user picked from the photo library, camera, or Files app (#8), before it's
/// turned into a `ComposerAttachment` (the reducer assigns the id).
public struct PickedItem: Equatable, Sendable {
  public var data: Data
  public var filename: String
  public var mimeType: String
  public var kind: ComposerAttachment.Kind

  public init(data: Data, filename: String, mimeType: String, kind: ComposerAttachment.Kind) {
    self.data = data
    self.filename = filename
    self.mimeType = mimeType
    self.kind = kind
  }

  /// Promote a picked file to a staged attachment (the reducer supplies the id).
  public func attachment(id: UUID) -> ComposerAttachment {
    ComposerAttachment(id: id, kind: kind, filename: filename, mimeType: mimeType, data: data)
  }
}

/// Presents the native photo / camera / document pickers and returns the selected files.
/// UIKit/PhotosUI live behind this dependency so reducers stay testable and platform-free.
@DependencyClient
public struct AttachmentPickerClient: Sendable {
  public var pickPhotos: @Sendable () async -> [PickedItem] = { [] }
  public var capturePhoto: @Sendable () async -> [PickedItem] = { [] }
  public var pickFiles: @Sendable () async -> [PickedItem] = { [] }
}

extension AttachmentPickerClient: DependencyKey {
  /// Tests get empty pickers by default; override a closure to return canned `PickedItem`s.
  public static var testValue: AttachmentPickerClient { AttachmentPickerClient() }
}

public extension DependencyValues {
  var attachmentPicker: AttachmentPickerClient {
    get { self[AttachmentPickerClient.self] }
    set { self[AttachmentPickerClient.self] = newValue }
  }
}

// MARK: - Live (iOS only)

#if canImport(UIKit)
  import PhotosUI
  import UIKit
  import UniformTypeIdentifiers

  extension AttachmentPickerClient {
    public static var liveValue: AttachmentPickerClient {
      AttachmentPickerClient(
        pickPhotos: { await PhotoPickerPresenter.present() },
        capturePhoto: { await CameraPresenter.present() },
        pickFiles: { await DocumentPickerPresenter.present() }
      )
    }
  }

  /// Walk to the top-most presented view controller of the active foreground scene.
  @MainActor
  private func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  private func mimeType(for url: URL) -> String {
    (UTType(filenameExtension: url.pathExtension)?.preferredMIMEType) ?? "application/octet-stream"
  }

  /// Bridges `PHPickerViewController` (multi-select images) to an async result.
  @MainActor
  private final class PhotoPickerPresenter: NSObject, PHPickerViewControllerDelegate {
    private var continuation: CheckedContinuation<[PickedItem], Never>?
    private static var retained: PhotoPickerPresenter?

    static func present() async -> [PickedItem] {
      await withCheckedContinuation { continuation in
        let presenter = PhotoPickerPresenter()
        presenter.continuation = continuation
        retained = presenter

        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0 // multiple
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = presenter

        guard let host = topViewController() else {
          presenter.finish([])
          return
        }
        host.present(picker, animated: true)
      }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      picker.dismiss(animated: true)
      guard !results.isEmpty else { finish([]); return }

      Task {
        var items: [PickedItem] = []
        for result in results {
          guard let item = await Self.loadImage(from: result.itemProvider) else { continue }
          items.append(item)
        }
        finish(items)
      }
    }

    private static func loadImage(from provider: NSItemProvider) async -> PickedItem? {
      // Prefer PNG; fall back to whatever image type the provider offers.
      let preferred = provider.registeredTypeIdentifiers.first {
        UTType($0)?.conforms(to: .image) == true
      } ?? UTType.image.identifier
      return await withCheckedContinuation { continuation in
        provider.loadDataRepresentation(forTypeIdentifier: preferred) { data, _ in
          guard let data else { continuation.resume(returning: nil); return }
          let ext = UTType(preferred)?.preferredFilenameExtension ?? "img"
          let mime = UTType(preferred)?.preferredMIMEType ?? "image/png"
          let name = (provider.suggestedName ?? "photo") + "." + ext
          continuation.resume(returning: PickedItem(data: data, filename: name, mimeType: mime, kind: .image))
        }
      }
    }

    private func finish(_ items: [PickedItem]) {
      continuation?.resume(returning: items)
      continuation = nil
      Self.retained = nil
    }
  }

  /// Bridges `UIImagePickerController` (camera capture) to an async result.
  @MainActor
  private final class CameraPresenter: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private var continuation: CheckedContinuation<[PickedItem], Never>?
    private static var retained: CameraPresenter?

    static func present() async -> [PickedItem] {
      await withCheckedContinuation { continuation in
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
          continuation.resume(returning: [])
          return
        }
        let presenter = CameraPresenter()
        presenter.continuation = continuation
        retained = presenter

        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = presenter

        guard let host = topViewController() else {
          presenter.finish([])
          return
        }
        host.present(picker, animated: true)
      }
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      picker.dismiss(animated: true)
      guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85) else {
        finish([]); return
      }
      finish([PickedItem(data: data, filename: "photo.jpg", mimeType: "image/jpeg", kind: .image)])
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      picker.dismiss(animated: true)
      finish([])
    }

    private func finish(_ items: [PickedItem]) {
      continuation?.resume(returning: items)
      continuation = nil
      Self.retained = nil
    }
  }

  /// Bridges `UIDocumentPickerViewController` (multi-select any file) to an async result.
  @MainActor
  private final class DocumentPickerPresenter: NSObject, UIDocumentPickerDelegate {
    private var continuation: CheckedContinuation<[PickedItem], Never>?
    private static var retained: DocumentPickerPresenter?

    static func present() async -> [PickedItem] {
      await withCheckedContinuation { continuation in
        let presenter = DocumentPickerPresenter()
        presenter.continuation = continuation
        retained = presenter

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = presenter

        guard let host = topViewController() else {
          presenter.finish([])
          return
        }
        host.present(picker, animated: true)
      }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      var items: [PickedItem] = []
      for url in urls {
        // asCopy: true delivers files into a temp dir we can read directly.
        guard let data = try? Data(contentsOf: url) else { continue }
        let mime = mimeType(for: url)
        items.append(PickedItem(
          data: data,
          filename: url.lastPathComponent,
          mimeType: mime,
          kind: .infer(mimeType: mime, filename: url.lastPathComponent)
        ))
      }
      finish(items)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      finish([])
    }

    private func finish(_ items: [PickedItem]) {
      continuation?.resume(returning: items)
      continuation = nil
      Self.retained = nil
    }
  }
#else
  extension AttachmentPickerClient {
    public static var liveValue: AttachmentPickerClient { testValue }
  }
#endif
