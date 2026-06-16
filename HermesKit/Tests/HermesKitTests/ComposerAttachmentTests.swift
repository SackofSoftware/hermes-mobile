import Foundation
import Testing

@testable import HermesKit

struct ComposerAttachmentTests {
  @Test func inferKindByMimeType() {
    #expect(ComposerAttachment.Kind.infer(mimeType: "image/png", filename: "a.png") == .image)
    #expect(ComposerAttachment.Kind.infer(mimeType: "image/jpeg", filename: "a.jpg") == .image)
    #expect(ComposerAttachment.Kind.infer(mimeType: "application/pdf", filename: "a.pdf") == .pdf)
    #expect(ComposerAttachment.Kind.infer(mimeType: "text/plain", filename: "a.txt") == .file)
  }

  @Test func inferKindFallsBackToExtensionWhenMimeIsGeneric() {
    let generic = "application/octet-stream"
    #expect(ComposerAttachment.Kind.infer(mimeType: generic, filename: "scan.PDF") == .pdf)
    #expect(ComposerAttachment.Kind.infer(mimeType: generic, filename: "pic.JPG") == .image)
    #expect(ComposerAttachment.Kind.infer(mimeType: generic, filename: "notes.bin") == .file)
  }

  @Test func dataURLAndBase64Helpers() {
    let attachment = ComposerAttachment(
      id: UUID(), kind: .image, filename: "p.png", mimeType: "image/png", data: Data([0xDE, 0xAD])
    )
    #expect(attachment.base64 == "3q0=")
    #expect(attachment.dataURL == "data:image/png;base64,3q0=")
  }
}
