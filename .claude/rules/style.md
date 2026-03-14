# UI Style

## Color

Use ANSI semantic colors exclusively. All colors must use `.index` values so the sidebar adapts to whatever terminal theme the user has active (Nord, Catppuccin, Tokyo Night, etc.).

**Never** use hardcoded RGB values. **Never** use `.rgb = .{ .r, .g, .b }`.

The color palette is defined in the `theme` struct in `render.zig`:

| Name           | Index             | Usage                                           |
| -------------- | ----------------- | ----------------------------------------------- |
| `selection_bg` | 8 (bright black)  | Selected row background                         |
| `dim`          | 8 (bright black)  | Borders, help labels, window counts             |
| `text`         | default           | Session names (normal)                          |
| `text_bright`  | 15 (bright white) | Selected session name                           |
| `accent`       | 14 (bright cyan)  | Title glyph, help keys, agent waiting indicator |
| `current`      | 2 (green)         | Current session indicator                       |
| `activity`     | 3 (yellow)        | Other-client-attached indicator                 |
| `kill_bg`      | 1 (red)           | Pending kill row background                     |
| `kill_fg`      | 15 (bright white) | Pending kill row text                           |

## Indicators

Indicator priority order (highest first):

1. `✸` agent waiting (accent color) — top priority, always shows
2. `●` current session (green)
3. `○` another client attached (yellow)
4. ` ` blank — no indicator

## Layout

- Box-drawn border around the entire sidebar using `┌─┐│└─┘` characters.
- Title in top border: `⊞ amux` — both the glyph (U+229E) and text are bold + accent color.
- Help text at the bottom: two lines inside the border. Keys in accent color, labels in dim.
- Session path shown below the selected session only (dimmed + italic), with HOME shortened to `~` and left-truncation with `…`.
- Window count right-aligned with 1-character right margin inside the border.
- Scroll indicators `▲`/`▼` shown when sessions exist above/below the visible area.

## Design principles

- No emoji. No ASCII art during active use.
- Color conveys meaning, not decoration.
- 1-line headers max. Borders carry titles.
- Keyboard-only navigation. No mouse support.
