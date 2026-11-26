# Motion tools

Browser pages used to design Winnow's keep/delete animation. Open them locally in a browser.

- `motion-trace.html`: the trace animation with live settings (trace speed, fade, fade start, line thickness, glow,
  edge sensitivity, colours) and a grid-mode demo. "Copy settings" gives the values; the app's copy of them is
  `Motion` in `lib/fx.dart` (keep both in step when retuning).
- `motion-options.html`: the first round of options (edge sweep, rise & sink, border trace, color wipe, burst lift).

Current values (2026-11-26): trace 710 ms, fade 560 ms starting at 75% of the trace, line 2.4, glow 15,
sensitivity 120, keep #60a5fa -> #f472b6, delete #991b1b -> #f97316, kept photos stay, deleted fade in place.
