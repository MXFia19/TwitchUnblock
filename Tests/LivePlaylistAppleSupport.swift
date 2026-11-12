// Minimal app dependencies for typechecking the shared playback services against
// the real Apple frameworks in CI, without building UI or contacting Twitch.
typealias QualityLinks = [String: String]
struct PlaylistTestLogger {
    func info(_ category: String, _ message: String, _ detail: String? = nil) {}
}
let logger = PlaylistTestLogger()
