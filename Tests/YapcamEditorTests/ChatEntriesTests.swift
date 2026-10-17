import Testing
@testable import YapcamEditor

@Suite struct ChatEntriesTests {
    @Test func replyLeadIsTheFirstParagraph() {
        let s = ChatReply.split("Tightened the pauses.\nKept the intro.\n\n  \nDetails: three cuts.\n\nAnd a zoom.")
        #expect(s.lead == "Tightened the pauses.\nKept the intro.")
        #expect(s.rest == "Details: three cuts.\n\nAnd a zoom.")
        #expect(ChatReply.split("One paragraph.").rest == nil)
    }

    @Test func replyThatOnlyRepeatsTheChangesIsHidden() {
        let changes = [AgentChange(label: "Zoom 1.8× on click 0:42"), AgentChange(label: "Tightened 3 pauses")]
        let mcp = AgentEntry(role: .agent, source: "Claude Code via MCP", text: "Zoom 1.8× on click 0:42, Tightened 3 pauses", changes: changes)
        #expect(ChatReply.visibleText(of: mcp) == nil)
        let chat = AgentEntry(role: .agent, source: "Chat", text: " Done. \n", changes: changes)
        #expect(ChatReply.visibleText(of: chat) == "Done.")
    }

    @Test func rowsGetASymbolPerKindAndNoDuplicateTime() {
        func symbol(_ label: String, _ symbol: String = "sparkles") -> String { ChatChangeStyle.symbol(for: AgentChange(label: label, symbol: symbol)) }
        #expect(symbol("Cut 0:12–0:14 ‘um’", "scissors") == "scissors")
        #expect(symbol("Zoom 1.8× on click 0:42", "plus.magnifyingglass") == "plus.magnifyingglass")
        #expect(symbol("Caption ‘Hi’ 0:00", "text.bubble") == "textformat")
        #expect(symbol("Background: wallpaper Sonoma") == "paintbrush")
        #expect(symbol("Padding 10 %") == "paintbrush")
        #expect(symbol("Clip speed 2×") == "gauge.with.needle")
        #expect(symbol("Cursor visible: on") == "slider.horizontal.3")
        #expect(symbol("Something new") == "sparkles")
        #expect(ChatChangeStyle.title("Zoom 1.8× on click 0:42", value: "0:42") == "Zoom 1.8× on click")
        #expect(ChatChangeStyle.title("Cut 0:12–0:14 ‘um’", value: "0:12") == "Cut 0:12–0:14 ‘um’")
        #expect(ChatChangeStyle.title("Removed zoom", value: "") == "Removed zoom")
    }
}
