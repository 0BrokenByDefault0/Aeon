# Aeon project requirements

- Never introduce emoji into app UI, source, documentation, or test output. Use named SVG icons or plain text instead. Preserve user-owned music metadata.
- Preserve the near-clear glass, white typography, and vibrant sky unless the user requests changes.
- The ground is true black, for OLED. Ambient dust stays near the threshold of visibility; album stars, planets and type are the only things that carry light.
- Corners are rounded on the scale in `AeonTheme.Radius`; edges are gradient hairlines that fade, never boxed borders. Square borders were retired at the user's request.
- Two faces: Clash Display Semibold for the names of things, Switzer for everything you operate. No third face, no serif display face, no mono. Address both by the PostScript names of static cuts so Dynamic Type keeps working.
- Chrome takes no space it does not need: glyph navigation over a scrim, never a docked bar.
- `docs/design/ui-shell.html` is the living reference for the skin; keep it and the SwiftUI/Metal implementation in step.
