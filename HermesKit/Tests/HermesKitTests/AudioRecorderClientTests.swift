import Testing

@testable import HermesKit

struct AudioRecorderClientTests {
  // MARK: dBFS → 0...1 normalization (waveform input)

  @Test func silenceFloorClampsToZero() {
    #expect(AudioRecorderClient.normalizeLevel(dBFS: -160) == 0)
    #expect(AudioRecorderClient.normalizeLevel(dBFS: -50) == 0)
    #expect(AudioRecorderClient.normalizeLevel(dBFS: -80) == 0)
  }

  @Test func fullScaleClampsToOne() {
    #expect(AudioRecorderClient.normalizeLevel(dBFS: 0) == 1)
    #expect(AudioRecorderClient.normalizeLevel(dBFS: 5) == 1)
  }

  @Test func midRangeMapsLinearlyAcrossTheFloor() {
    #expect(AudioRecorderClient.normalizeLevel(dBFS: -25) == 0.5)
    #expect(abs(AudioRecorderClient.normalizeLevel(dBFS: -10) - 0.8) < 0.0001)
  }

  // MARK: Test double behavior

  @Test func testValueGrantsPermissionAndReturnsCannedAudio() async throws {
    let client = AudioRecorderClient.testValue
    #expect(await client.requestPermission() == true)
    try await client.startRecording()
    let audio = try await client.stopRecording()
    #expect(audio.mimeType == "audio/m4a")
    #expect(!audio.data.isEmpty)
  }

  @Test func testValueLevelsStreamEmitsThenFinishes() async {
    let client = AudioRecorderClient.testValue
    var collected: [Float] = []
    for await level in client.levels() { collected.append(level) }
    // Finite stream so the for-await terminates (a hung stream would deadlock the test).
    #expect(collected == [0.2, 0.6, 0.4])
  }
}
