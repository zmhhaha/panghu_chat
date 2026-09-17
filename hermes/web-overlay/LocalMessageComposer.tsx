import { useRef, useState } from "react";

type Props = {
  socket: WebSocket | null;
  connected: boolean;
  onTerminalMode: () => void;
};

export function LocalMessageComposer({ socket, connected, onTerminalMode }: Props) {
  const [value, setValue] = useState("");
  const [pending, setPending] = useState(false);
  const [notice, setNotice] = useState("");
  const composing = useRef(false);

  const submit = () => {
    const text = value.replace(/\r\n?/g, "\n").trim();
    if (!text || pending) return;
    if (!connected || !socket || socket.readyState !== WebSocket.OPEN) {
      setNotice("Chat is reconnecting. Your draft is kept.");
      return;
    }

    // Hermes' TUI understands bracketed paste and keeps embedded newlines in
    // one composer submission. The final CR is the only submit action.
    setPending(true);
    setNotice("Sending…");
    try {
      socket.send(`\x1b[200~${text}\x1b[201~`);
      window.setTimeout(() => {
        if (socket.readyState === WebSocket.OPEN) socket.send("\r");
        setValue("");
        setPending(false);
        setNotice("");
      }, 40);
    } catch {
      setPending(false);
      setNotice("Send failed. Your draft was kept.");
    }
  };

  return (
    <section aria-label="Message composer" className="mt-3 flex flex-col gap-2">
      <textarea
        aria-label="Message"
        className="min-h-24 w-full resize-y rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground outline-none focus:ring-2 focus:ring-ring"
        disabled={pending}
        onChange={(event) => setValue(event.target.value)}
        onCompositionEnd={() => { composing.current = false; }}
        onCompositionStart={() => { composing.current = true; }}
        onKeyDown={(event) => {
          if (event.key === "Enter" && (event.ctrlKey || event.metaKey) && !composing.current) {
            event.preventDefault();
            submit();
          }
        }}
        placeholder="Write a message…"
        value={value}
      />
      <div className="flex items-center justify-between gap-2">
        <span aria-live="polite" className="text-xs text-muted-foreground">{notice}</span>
        <div className="flex gap-2">
          <button className="rounded-md border border-border px-3 py-1.5 text-sm" onClick={onTerminalMode} type="button">
            Terminal
          </button>
          <button className="rounded-md bg-primary px-3 py-1.5 text-sm text-primary-foreground disabled:opacity-60" disabled={!value.trim() || pending} onClick={submit} type="button">
            {pending ? "Sending…" : "Send"}
          </button>
        </div>
      </div>
    </section>
  );
}
