import Foundation
import Testing

@testable import HermesKit

struct ProfileNameTests {
  @Test(arguments: [
    "my-profile",
    "a",
    "a_b-c",
    "0",
    "work",
    "profile_1",
    String(repeating: "a", count: 64),
  ])
  func acceptsValidNames(_ name: String) {
    #expect(ProfileName.isValid(name) == true)
  }

  @Test(arguments: [
    "testOS",            // uppercase
    "-leading",          // leading hyphen
    "_leading",          // leading underscore
    "",                  // empty
    "   ",               // whitespace only
    "has space",         // space
    "Café",              // non-ascii / accent
    "with.dot",          // disallowed char
    String(repeating: "a", count: 65),  // too long
  ])
  func rejectsInvalidNames(_ name: String) {
    #expect(ProfileName.isValid(name) == false)
  }

  @Test func validatesTrimmedString() {
    #expect(ProfileName.isValid("  my-profile  ") == true)
    #expect(ProfileName.isValid("\twork\n") == true)
  }

  @Test func hintMatchesDesktopCopy() {
    #expect(
      ProfileName.hint
        == "Lowercase letters, digits, hyphens, and underscores. Must start with a letter or digit."
    )
  }
}
