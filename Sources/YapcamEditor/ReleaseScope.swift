/// What this release shows. The code behind a switched-off feature stays and keeps rendering existing projects;
/// only its way in (buttons, panel, palette entries, the agent's MCP server) is hidden.
public enum ReleaseScope {
    /// Agent chat, the building-blocks bar and the local MCP server (0.11.0: off).
    nonisolated(unsafe) public static var agent = false
    /// The "Text, regions & intro/outro" inspector panel and its palette entries (0.11.0: off).
    nonisolated(unsafe) public static var textRegionsPanel = false

    public static func ships(_ s: InspectorSection) -> Bool { s != .extras || textRegionsPanel }
}
