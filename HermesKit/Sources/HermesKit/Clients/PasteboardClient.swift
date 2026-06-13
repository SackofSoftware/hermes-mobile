import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Copies text to the system pasteboard. Abstracted as a dependency so the copy
/// action is testable without touching `UIPasteboard`.
@DependencyClient
public struct PasteboardClient: Sendable {
  public var copy: @Sendable (_ text: String) -> Void
}

extension PasteboardClient: DependencyKey {
  public static var liveValue: PasteboardClient {
    PasteboardClient(copy: { text in
      #if canImport(UIKit)
        UIPasteboard.general.string = text
      #endif
    })
  }

  /// Tests get a no-op by default; override `copy` to capture the copied text.
  public static var testValue: PasteboardClient {
    PasteboardClient(copy: { _ in })
  }
}

public extension DependencyValues {
  var pasteboard: PasteboardClient {
    get { self[PasteboardClient.self] }
    set { self[PasteboardClient.self] = newValue }
  }
}

#if canImport(UIKit)
  import UIKit
#endif
