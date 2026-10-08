---
status: Accepted
boundary: OSS-only
---

# ADR-2026-10-08-viewer-clipboard-from-osc52-set

**Status:** Accepted (2026-10-08, product-owner acceptance with the copy-preview requirement, rule 6)
**Date:** 2026-10-08
**Boundary:** OSS-only
**Authors:** Claude (agent), for the attach-protocol maintainers

## Context

`protocol/interactive-attach-v1.md` §9 (`v1-frozen`) strips OSC 52 from the viewer-bound stream: "paste-jacking / clipboard theft — never write a viewer clipboard from the stream".

Mouse-tracking TUIs copy through exactly that sequence. A REPL running full-screen with mouse reporting on (`?1000`/`?1002`/`?1003`/`?1006`) makes a selection on drag and then writes `ESC ] 52 ; c ; <base64> BEL`. It tells the user "copied N chars to clipboard". Captured from a PTY:

```
1b 5d 35 32 3b 63 3b 49 43 42 … 07      ESC]52;c;ICBGYWJsZSA1LjEgwrcgQ2xhdWRlIE1heA==BEL
```

Behind an attach viewer, that copy never arrives:
- the sanitizer strips the sequence, and recordings show an output frame emptied at the moment of every such copy;
- because the session tracks the mouse, the viewer's own terminal makes no selection either, so the user has no way to copy at all.

The threat the §9 row names is real. A session's output is attacker-influenceable: repository content and tool output reach it. If OSC 52 were passed through to the viewer's terminal, that output could replace the operator's clipboard at any moment, with content the operator later pastes into a shell.

## Decision

OSC 52 stays **stripped from the stream**; the byte disposition and the conformance corpus do not change.

In addition, a viewer **MAY** offer the decoded text of an OSC 52 **set** to its local clipboard when **all** of the following hold:

1. **Set only.** The sequence is `52 ; Pc ; Pd` where `Pd` is non-empty, valid base64, and decodes to valid UTF-8.
   - A query (`Pd = ?`) is never answered and never forwarded.
   - A clear (empty `Pd`) is ignored.
   - Control characters other than HT, LF and CR are removed from the text.
2. **Input-control holder.** The viewer holds the pen. Only the pen holder's input reaches the session, so only their action can have caused the copy. A spectator never receives another user's copy.
3. **Own recent gesture.** The pen holder's own input reached the session within a short window: at most 2 s, ending at their latest input to this session. On the web that input is a mouse button or key press in the terminal; in a terminal viewer it is input forwarded to the session.
4. **One write per gesture.** A gesture admits at most one write, so a session cannot keep overwriting the clipboard.
5. **Bounded.** The size is bounded by `sanitizerHoldMaxBytes`: a longer set is stripped whole without being offered. A viewer may apply a smaller cap.
6. **Visible preview.** Every write the viewer forwards to a clipboard shows a short, visible notice of what was copied, so a substituted clipboard is visible before it is pasted. The notice carries:
   - the first characters of the decoded text (about 40), with line breaks, tabs, and every other control or invisible formatting character (zero-width, bidi override) rendered visibly, so nothing in the text can hide or reorder what the notice shows;
   - the total length;
   - a multi-line marker (the line count) when the text spans more than one line.

   A web viewer shows it as a transient notice (for example `Copied: "npm run build⏎npm test" · 22 chars · 2 lines`); a terminal viewer flashes it in its status line. A write the viewer drops never shows the preview. When the input-control holder's copy is dropped (no recent gesture, over the size cap, or refused by the local clipboard), the viewer shows a "copy blocked" notice instead. A viewer that does not hold input control stays silent.

A viewer that forwards to a terminal emits the 7-bit form `ESC ] 52 ; c ; <base64> ESC \`. The operator's terminal then applies its own OSC 52 policy.

Reference implementation: `attachwire/sanitize`.
- `Options.OnClipboard` receives the decoded text of a set. The stream output is unchanged.
- `DecodeClipboardSet` and `ClipboardSequence` are exported for viewers.

## Consequences

### Positive

- Copy-on-select in mouse-tracking TUIs works through attach viewers, and only as the direct result of the operator's own action.
- The stream contract, the corpus and every existing implementation stay byte-identical. Viewers opt in through the hook.

### Negative

- A session that knows the operator just pressed a key or clicked can, within the window, put **different** text on the clipboard than what was selected. The viewer cannot see the session's selection to compare. Rules 2–4 shrink the window to one write the operator triggered, and rule 6 makes a substitution visible before the operator pastes. They do not prevent it.
- Browsers can refuse the write once their own user-activation window has passed. Web viewers must surface that ("copy blocked by the browser").

### Risks

- A viewer that implements the hook without rules 2–4 reopens the §9 threat, and one without rule 6 hides a substitution until paste. The rules are normative for any viewer that offers the text.

## Alternatives considered

- **Pass OSC 52 through to the viewer's terminal.** This gives the session unconditional clipboard write. Rejected: it is the threat §9 names.
- **Keep stripping and offer nothing.** This is the status quo. Copy is impossible under mouse tracking unless the user knows the terminal's force-select modifier. Viewers should still offer that path (a force-select modifier, or a mode that turns mouse reporting off locally), and the reference viewers do. But the session's own copy is what users reach for.

## Affected documents

- `protocol/interactive-attach-v1.md` §9 (edited in the accepting commit). The OSC 52 row's disposition stays **strip**, and its rationale now names this ADR's exception. A paragraph after the table states rules 1–6 in brief. The frozen byte-level disposition and the conformance corpus are unchanged.

This ADR has no platform-specific portion. The protocol and its §9 table are canonical in this corpus only, so no mirrored stub is required.

## Affected work items

None tracked in this corpus.

## Implementation notes

The reference viewers apply rules 2–4 in their input paths: the web viewer's terminal element and the terminal viewer's forwarded input. Each renders rule 6's preview with one shared format and surfaces a dropped or refused write as a "copy blocked" notice (pen holder) or a log line (spectator).
