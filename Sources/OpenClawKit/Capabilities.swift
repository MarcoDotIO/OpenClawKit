import Foundation

/// Node capability identifiers advertised in `connect.caps`.
public enum OpenClawCapability: String, Codable, Sendable {
    /// Canvas presenter (`canvas.present`/`hide`/`navigate`).
    case canvas
    case browser
    case camera
    case screen
    /// Desktop control (`computer.act`); advertise only while the host enables computer control.
    case computer
    case voiceWake
    /// Realtime talk mode.
    case talk
    case location
    case device
    case watch
    case photos
    case contacts
    case calendar
    case reminders
    case motion
    /// Aggregate health summaries (`health.summary`); advertise only while the user opted in.
    case health
}
