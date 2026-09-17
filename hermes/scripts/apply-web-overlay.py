from pathlib import Path

root = Path("/opt/hermes")
page = root / "web/src/pages/ChatPage.tsx"
component = Path("/opt/intelligence/web-overlay/LocalMessageComposer.tsx")
if not page.exists() or not component.exists():
    raise SystemExit("Hermes web source or overlay component is missing")

text = page.read_text(encoding="utf-8")
marker = 'import { LocalMessageComposer } from "@/components/LocalMessageComposer";\n'
if marker not in text:
    anchor = 'import { ChatSidebar } from "@/components/ChatSidebar";\n'
    if anchor not in text:
        raise SystemExit("ChatPage import anchor changed upstream")
    text = text.replace(anchor, anchor + marker, 1)

component_target = root / "web/src/components/LocalMessageComposer.tsx"
component_target.write_text(component.read_text(encoding="utf-8"), encoding="utf-8")

mount = '''\n          <LocalMessageComposer\n            connected={ptyState === "open"}\n            onTerminalMode={() => termRef.current?.focus()}\n            socket={wsRef.current}\n          />\n'''
if "<LocalMessageComposer" not in text:
    anchor = '''          <div\n            ref={hostRef}\n            className="hermes-chat-xterm-host min-h-0 min-w-0 flex-1"\n          />\n'''
    if anchor not in text:
        raise SystemExit("ChatPage terminal host anchor changed upstream")
    text = text.replace(anchor, anchor + mount, 1)

page.write_text(text, encoding="utf-8")
