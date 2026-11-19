# Changelog

Notable changes to the Hardware Monitor plugin, newest first. The version lives
in `manifest.json`; `scripts/release.sh X.Y.Z` turns the Unreleased notes below
into a dated version entry, bumps the manifest to match, and commits and tags
the release.

Releases up to 1.2.1 were not tagged. Their release commits are 1.0.0
`f9aa323`, 1.1.0 `8e1fd16`, 1.1.1 `7c577c0`, 1.2.0 `ff91bb8` and 1.2.1
`c217fdb`.

## Unreleased

### Added

- `scripts/check.sh`, a pre-push check (manifest validation, manifest defaults
  against the schema, syntax of every helper and QML file), and
  `scripts/release.sh` with this changelog.
- README: a Development section on trying a checkout in your own bar.

### Changed

- README and manifest descriptions now match the code: the panel header and
  its settings drawer (gear or `s`), the mode-dependent `showGauges` default,
  how `gpu: "auto"` picks a card and what an unmatched value does, `monitors`
  and `itemsOrder` as comma-separated strings, top processes by RAM or CPU,
  and rows for `padOpacity` and the four glyph rotation settings.

## 1.2.1 — 2026-10-16

### Fixed

- Helper output is treated as untrusted: the probe's JSON keeps only known
  keys, and a sensor path is accepted only under `/sys` or `/proc`, with path
  traversal refused and control characters stripped.
- Every helper process is bounded in time and output size, and a failed probe
  retries discovery after 30 seconds instead of leaving the widget without
  sensors until the shell reloads.
- An idle Intel discrete GPU with no display attached is skipped, so sampling
  no longer keeps it awake; with `nvidia-smi` installed but no NVIDIA card, its
  error text is no longer shown as a GPU name (#4).
- Glyphs from settings render as plain text, and `padOpacity` and the glyph
  rotation settings appear in the settings schema.

## 1.2.0 — 2026-10-10

### Added

- A top-processes section in the system panel, sorted by RAM or CPU and
  grouped by application, sampled only while the panel is open (#2, #3).

### Fixed

- Bar figure cells reserve their width, so the readout no longer shifts as
  numbers change (#3).

## 1.1.1 — 2026-09-29

### Added

- A settings drawer in the system panel (gear button or `s`) for readout mode,
  shown items, RAM and temperature format, and °C/°F.
- Settings for which items the bar shows and in what order, and more
  `ramFormat` and `tempFormat` options.

### Changed

- The plugin id is now `meviusisback.hw-monitor`; this fork continues Edgar
  Silva's original plugin.
- The `icons` readout shows GPU load, CPU load, CPU temperature with a
  thermometer glyph, and RAM.

### Fixed

- Panel layout clipping, doubled degree signs, a Tab navigation error, and
  missing temperatures in `full` mode.
- Bar glyphs follow the theme's foreground colour.

## 1.1.0 — 2026-09-01

### Added

- The `icons` readout, now the default: a glyph and a figure per component.
- A system panel on left click, with dials, a 60-second CPU load history, and
  processor, memory and GPU details.
- `monitors`, to draw the widget only on chosen screens.

## 1.0.0 — 2026-08-18

- First release: memory, CPU and GPU in the Omarchy bar as `compact`, `full`
  and `labels` readouts, read from `/proc` and `/sys`.
