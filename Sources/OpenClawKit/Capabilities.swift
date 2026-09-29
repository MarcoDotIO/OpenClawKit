import Foundation

/// Node capability identifiers advertised in `connect.caps`.
///
/// Advertise a capability only while the matching commands are implemented and enabled; the gateway
/// uses caps to decide which node commands it may route to this device.
public enum OpenClawCapability: String, Codable, Sendable {
    /// Canvas presenter (`canvas.present`/`hide`/`navigate`, see ``OpenClawCanvasCommand/presenterCommands``).
    case canvas
    /// Browser proxy commands.
    case browser
    /// Camera capture (`camera.*`).
    case camera
    /// Screen capture and recording (`screen.*`).
    case screen
    /// Desktop control (`computer.act`); advertise only while the host enables computer control.
    case computer
    /// Voice wake-word detection.
    case voiceWake
    /// Realtime talk mode (`talk.*` push-to-talk and the gateway relay).
    case talk
    /// Location (`location.*`).
    case location
    /// Device information (`device.*`).
    case device
    /// Apple Watch companion (`watch.*`).
    case watch
    /// Photos library (`photos.*`).
    case photos
    /// Contacts (`contacts.*`).
    case contacts
    /// Calendar events (`calendar.*`).
    case calendar
    /// Reminders (`reminders.*`).
    case reminders
    /// Motion and fitness (`motion.*`).
    case motion
    /// Aggregate health summaries (`health.summary`); advertise only while the user opted in.
    case health
}
