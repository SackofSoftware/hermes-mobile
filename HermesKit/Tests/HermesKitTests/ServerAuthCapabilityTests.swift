import Foundation
import Testing

@testable import HermesKit

struct ServerAuthCapabilityTests {
  private func status(authRequired: Bool?) -> ServerStatus {
    var s = ServerStatus()
    s.authRequired = authRequired
    return s
  }

  // MARK: Table-driven mapper cases

  @Test func authNotRequiredIsTokenOnly() {
    // Loopback/--insecure: auth_required false → token-only, even if providers are present.
    let providers = [AuthProvider(name: "basic", displayName: "Username & password", supportsPassword: true)]
    #expect(ServerAuthCapability(from: status(authRequired: false), providers: providers) == .tokenOnly)
  }

  @Test func authRequiredAbsentIsTokenOnly() {
    // Older server: no auth_required field at all → token-only.
    #expect(ServerAuthCapability(from: status(authRequired: nil), providers: nil) == .tokenOnly)
  }

  @Test func gatedWithBasicIsPasswordAvailable() {
    let providers = [AuthProvider(name: "basic", displayName: "Username & password", supportsPassword: true)]
    #expect(
      ServerAuthCapability(from: status(authRequired: true), providers: providers)
        == .passwordAvailable(provider: "basic", displayName: "Username & password")
    )
  }

  @Test func gatedWithOAuthOnlyIsOAuthOnly() {
    let providers = [AuthProvider(name: "google", displayName: "Google", supportsPassword: false)]
    #expect(
      ServerAuthCapability(from: status(authRequired: true), providers: providers)
        == .oauthOnly(providers: providers)
    )
  }

  @Test func gatedMixedPrefersPassword() {
    // OAuth listed first, but a password-capable provider exists → password preferred.
    let providers = [
      AuthProvider(name: "google", displayName: "Google", supportsPassword: false),
      AuthProvider(name: "basic", displayName: "Password", supportsPassword: true),
    ]
    #expect(
      ServerAuthCapability(from: status(authRequired: true), providers: providers)
        == .passwordAvailable(provider: "basic", displayName: "Password")
    )
  }

  @Test func gatedWithNoProvidersFallsBackToTokenOnly() {
    // Gated but providers endpoint 404'd (nil) — give the user a way in via token.
    #expect(ServerAuthCapability(from: status(authRequired: true), providers: nil) == .tokenOnly)
    #expect(ServerAuthCapability(from: status(authRequired: true), providers: []) == .tokenOnly)
  }

  // MARK: AuthProvider decoding leniency

  @Test func authProviderDecodesFullPayload() throws {
    let json = #"{"name":"basic","display_name":"Username & password","supports_password":true}"#
    let provider = try JSONDecoder().decode(AuthProvider.self, from: Data(json.utf8))
    #expect(provider == AuthProvider(name: "basic", displayName: "Username & password", supportsPassword: true))
  }

  @Test func authProviderDecodesMissingFieldsLeniently() throws {
    // Missing display_name → falls back to name; missing supports_password → false.
    let json = #"{"name":"basic"}"#
    let provider = try JSONDecoder().decode(AuthProvider.self, from: Data(json.utf8))
    #expect(provider == AuthProvider(name: "basic", displayName: "basic", supportsPassword: false))
  }
}
