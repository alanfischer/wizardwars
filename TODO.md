# TODO

## Library promotion

Every library is tagged (2026-11-09: goldsrc-godot v0.4.0, hop-godot v0.2.0, goldnet-godot v0.2.0,
overcast-godot v0.1.0, pmove-godot v0.1.0, hop and goldnet cores v0.1.0) and WW is pinned at the tags.

- goldnet-godot: Godot Asset Library, a write-up around the 25%-loss table, and each "What we
  wish Godot had" item filed as a godot-proposals issue linking back.
- pmove-godot: Asset Library, with a GIF of the demo.
- overcast-godot: the screenshots, in a showcase thread.

## Map fidelity

- Alternate textures (`+a`..`+j`) never switch. GoldSrc draws a brush entity's alternate
  sequence while its `pev->frame` is 1: func_button / func_rot_button while pressed
  (BUTTONS.CPP:720, 741), func_wall on each use (BMODELS.CPP:80), button_target on use or with
  SF_BTARGET_ON (BUTTONS.CPP:1245, 1252). No rotation map shows the gap today: ravine's and
  wstland4's `+a` lights are on worldspawn, which never switches, and chasm's are on
  func_wall_toggle, which hides rather than switching frame. With the GPU flipbook (goldsrc #82)
  the alternate set would be a second frame array on the material; materials are shared per
  (texture, lightmap page), so a switch has to be per entity (its own material or an instance
  uniform), not a write to the shared one.
