# JKA BSP Importer

The add-on now includes a Godot editor plugin: add a **JkaBspMap** node, choose a BSP from its Inspector dropdown, and click **Build Map**. See [PLUGIN.md](PLUGIN.md) for setup and usage. The lower-level inspection scripts described below remain available.

Read-only Godot 4 GDScript reader for Raven **RBSP version 1**, used by the map-node plugin and inspection tools. It is independent of FuncGodot.

Open `inspect_in_editor.gd` in Godot's script editor and run it as an EditorScript. It inspects `res://maps/test2.bsp`, prints counts, and writes `user://bsp-inspection.json`. No scene is changed.

For a headless run:

```text
Godot.exe --headless --path PROJECT --script res://addons/jka_bsp/inspect_bsp.gd -- res://maps/test2.bsp REPORT.json
```

`bsp_reader.gd.read_bsp(path)` returns a dictionary with `ok`, `errors`, `warnings`, the lump directory, raw entity text, visibility dimensions, and decoded record arrays. Use `summary()` for a JSON-friendly directory, counts, materials, sample vertices, and patch grids with a sample control point. Original map coordinates and UVs are preserved; no axis conversion or scaling occurs.

The reader uses little-endian FileAccess reads and seeks to each lump. It decodes shaders, planes, nodes, leaves, leaf references, models, brushes/sides, vertices, indices, fogs, and surfaces. Patch surfaces retain their width/height and vertex span: those vertices are control points, not a finished tessellated mesh. Each vertex contains position, UV, four lightmap UV pairs, normal, and four RGBA colors.

Checks cover header/version, lump bounds/overlap/strides, core cross-references, triangle indices, patch grid dimensions, and finite geometry fields. Non-finite lightmap UVs produce warnings and remain unchanged in memory. These warnings must be handled before lighting import. Validation is structural, not proof of correct visual rendering, BSP tree acyclicity, or complete game compatibility.

Lightmap images, light-grid records, and light-array entries are currently counted and range-checked but not decoded. Visibility bitsets are size-checked but not retained. Entity text is read without spawning or interpreting entities. External textures/shaders are not loaded.

Reference layout: https://github.com/JACoders/OpenJK/blob/master/code/qcommon/qfiles.h

`test_reader.gd` checks test2 and deliberately corrupted copies (written only into `res://bsp-test-fixtures`). Run with `--headless --script res://addons/jka_bsp/test_reader.gd`.
