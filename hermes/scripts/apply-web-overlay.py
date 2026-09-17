from pathlib import Path
import re

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

mount = '''
          <LocalMessageComposer
            key={JSON.stringify([scopedProfile ?? "", resumeParam ?? "", channel])}
            connected={ptyState === "open"}
            ended={ptyState === "ended"}
            draftKey={`hermes.local-composer.v2.${JSON.stringify([scopedProfile ?? "", resumeParam ?? ""])}`}
            onTerminalMode={() => termRef.current?.focus()}
            socket={wsRef.current}
          />
'''
layout_marker = 'data-hermes-local-composer-column="true"'
existing_mount = re.compile(r"[ \t]*<LocalMessageComposer\b[\s\S]*?\n[ \t]*/>")
if len(existing_mount.findall(text)) > 1:
    raise SystemExit("Multiple local composer mounts found; review upstream layout")
if layout_marker in text:
    text, count = existing_mount.subn(lambda _: mount.strip("\n"), text)
    if count != 1:
        raise SystemExit("Local composer column exists without a recognized mount")
if layout_marker not in text:
    # Migrate the old mount inside the positioned terminal container as well.
    text = existing_mount.sub("", text)
    start = '''        <div\n          ref={termWrapRef}'''
    end = '''        </div>\n\n        {!narrow && !chatPanelCollapsed && ('''
    if text.count(start) != 1 or text.count(end) != 1:
        raise SystemExit("ChatPage terminal column anchors changed upstream")
    text = text.replace(
        start,
        '        <div data-hermes-local-composer-column="true" className="flex min-h-0 min-w-0 flex-1 flex-col gap-2">\n' + start,
        1,
    )
    text = text.replace(
        end,
        '        </div>\n' + mount + '        </div>\n\n        {!narrow && !chatPanelCollapsed && (',
        1,
    )

page.write_text(text, encoding="utf-8")
