import Foundation

/// Canvas presenter node commands.
///
/// Canvas commands are plugin-declared upstream (`src/gateway/node-command-policy.ts` treats `canvas.*`
/// as plugin node commands); only `canvas.present`, `canvas.hide` and `canvas.navigate` remain. Use
/// inline widgets (client cap `inline-widgets`, the `show_widget` tool) instead of A2UI or eval.
public enum OpenClawCanvasCommand: String, Codable, Sendable {
    /// `canvas.present`: show a hosted widget document.
    case present = "canvas.present"
    /// `canvas.hide`: hide the canvas panel.
    case hide = "canvas.hide"
    /// `canvas.navigate`: navigate the canvas to another widget URL.
    case navigate = "canvas.navigate"
    /// `canvas.eval`: retired; do not advertise.
    @available(*, deprecated, message: "Retired upstream in OpenClaw 2026.8.1 (#126030); canvas is a widget presenter")
    case evalJS = "canvas.eval"
    /// `canvas.snapshot`: retired; do not advertise.
    @available(*, deprecated, message: "Retired upstream in OpenClaw 2026.8.1 (#126030); canvas is a widget presenter")
    case snapshot = "canvas.snapshot"

    /// Commands a canvas-capable node should advertise by default (the retired ones are excluded).
    public static let presenterCommands: [OpenClawCanvasCommand] = [.present, .hide, .navigate]
}
