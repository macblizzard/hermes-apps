"""Structural guards for the macOS workspace after the bot-first rewrite.

These run without Xcode or the macOS SDK. They pin the layout the user asked for: a bot-only
left sidebar, a chat-only right side, a working animation on the right bot, native-menu
reachability for pairing/settings, and the two prior fixes (the title-bar gap and the retired
icon rail) staying in place.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Apps/HermesMac"


class MacWorkspaceRailRegressionTests(unittest.TestCase):
    def test_workspace_shell_is_sidebar_plus_chat_only(self):
        source = (MAC / "Workspace/WorkspaceRoot.swift").read_text()
        self.assertNotIn("IconRail(", source)
        self.assertNotIn("Geometry.serverRailMacOS", source)
        self.assertNotIn("ContextPanelView(", source)
        self.assertNotIn("showsContextPanel", source)
        self.assertIn("SessionSidebarView(model: model, store: store)", source)
        self.assertIn("ConversationPane(model: model, store: store)", source)

    def test_retired_rail_views_are_gone(self):
        self.assertFalse((MAC / "Workspace/IconRail.swift").exists())
        self.assertFalse((MAC / "Workspace/BotRail.swift").exists())

    def test_window_minimum_no_longer_reserves_the_rail(self):
        source = (MAC / "HermesMacApp.swift").read_text()
        self.assertNotIn("Geometry.serverRailMacOS +", source)
        self.assertIn("Geometry.sidebarMin + Geometry.conversationMin", source)

    def test_sidebar_is_bot_only(self):
        source = (MAC / "Sidebar/SessionSidebarView.swift").read_text()
        for retired in (
            "HostStatusBar(",
            "MacSidebarSearchField(",
            "SessionRow(",
            "SessionGrouping",
            "Search sessions",
        ):
            self.assertNotIn(retired, source)
        self.assertIn("SidebarBotList(model: model,", source)
        self.assertIn("showsHiddenBots: $showsHiddenBots", source)
        self.assertIn("store.selectBot(bot.id)", source)
        self.assertIn("store.openPalette()", source)
        self.assertIn('label: "Pair host…"', source)

    def test_bot_rows_show_icons_and_animate_the_working_bot(self):
        source = (MAC / "Sidebar/SidebarBotList.swift").read_text()
        self.assertIn("BotIconPortrait(icon, size: 30", source)
        self.assertIn("isWorking: model.isBotWorking(bot.id)", source)
        self.assertIn("model.isBotWorking(bot.id)", source)

    def test_native_menus_keep_pairing_and_settings(self):
        source = (MAC / "HermesMacApp.swift").read_text()
        self.assertIn('Button("Pair Host…")', source)
        self.assertIn("Manage Paired Devices…", source)
        self.assertIn('CommandMenu("Bot")', source)
        self.assertIn('Button("Bot Settings…")', source)
        self.assertIn("store.openBotSettings", source)

    def test_no_session_browser_or_context_panel_commands_remain(self):
        store = (MAC / "Workspace/WorkspaceStore.swift").read_text()
        header = (MAC / "Conversation/ConversationHeader.swift").read_text()
        for source in (store, header):
            self.assertNotIn("New session", source)
            self.assertNotIn("Reload sessions", source)
            self.assertNotIn("context panel", source.lower())
        self.assertNotIn("searchText", store)

    def test_composer_pastes_images_and_opens_the_menu_above(self):
        source = (MAC / "Conversation/MacComposerBar.swift").read_text()
        self.assertIn(".onPasteCommand(of: [.image])", source)
        self.assertIn("MacAttachmentFile.pastedImage()", source)
        self.assertIn("model.addPendingAttachment(name: pasted.name", source)
        self.assertIn(".overlay(alignment: .topLeading)", source)
        self.assertIn("MacAttachmentMenu.height", source)
        self.assertIn("hasAttachments: !model.pendingAttachments.isEmpty", source)
        self.assertNotIn(".popover(isPresented: $showsAttachmentMenu", source)

        store = (MAC / "Workspace/WorkspaceStore.swift").read_text()
        self.assertIn("!model.pendingAttachments.isEmpty", store,
                      "an image with no caption is a complete message")

    def test_pasted_image_is_read_from_the_native_pasteboard(self):
        source = (MAC / "Conversation/MacAttachmentMenu.swift").read_text()
        self.assertIn("NSPasteboard = .general", source)
        self.assertIn("pasteboard.data(forType:", source)
        self.assertIn("MacAttachmentFile(name: name, data: data, isImage: true)", source)
        self.assertNotIn("strokeBorder", source,
                         "the Photos/Files menu has no permanent outline")

    def test_canonical_conversation_identity_is_server_side_title(self):
        source = (ROOT / "Sources/HermesAppKit/AppModel.swift").read_text()
        self.assertIn('canonicalConversationTitle = "Bot Chat"', source)
        self.assertIn("client.sessionID(titled:", source)
        self.assertIn("client.setSessionTitle(", source)
        self.assertNotIn("client.mostRecentSession(profile:", source,
                         "a recent row is not proof of the shared conversation; never adopt it")

    def test_steer_is_a_separate_wire_verb_and_keeps_interrupt(self):
        model = (ROOT / "Sources/HermesAppKit/AppModel.swift").read_text()
        composer = (ROOT / "Sources/OpenBotUI/Composer.swift").read_text()
        mac_bar = (MAC / "Conversation/MacComposerBar.swift").read_text()
        store = (MAC / "Workspace/WorkspaceStore.swift").read_text()
        self.assertIn("client.steer(session: sid, text: text)", model)
        self.assertIn("public func steer() async", model)
        self.assertIn("onSteer: { store.steer() }", mac_bar)
        self.assertIn("interruptButton(onInterrupt)", composer)
        self.assertIn('Text("Steer")', composer)
        self.assertIn("func steer()", store)
        self.assertIn("!model.isStreaming", store)

    def test_previous_title_bar_gap_fix_is_unchanged(self):
        source = (MAC / "Workspace/WorkspaceChrome.swift").read_text()
        self.assertIn("max(0, titleBarHeight - max(0, safeAreaTop))", source)


if __name__ == "__main__":
    unittest.main()
