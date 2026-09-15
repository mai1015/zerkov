# Map-study verification

Local execution used real standard Godot 4.7.2.stable.official.ed1daf0bf,
OpenGL Compatibility, Mesa/llvmpipe and Xvfb at physical 1920x1080. The world
render target remained 640x360 at exact 3x nearest scaling and camera zoom one.

Local tests: 15 Python source/geometry/topology tests passed. Two independent
graphical process runs each reported 29 checks and zero failures (58 repeated
checks, not 58 distinct cases). All seven native PNG files matched byte-for-byte
between runs. Two exact Xvfb unsupported-VSync notices were counted; other
warnings/errors are test failures. The actual source rebuild also matched the
recorded atlas hash. `capture.json` seals input files and native PNGs.

Input tests dispatch actual Godot mouse/key events to map/sector/annotation
controls. Camera limits, native collision creation, and repeated replacement
are tested. Python checks region bounds, source identities, final collider
footprints, exit connectivity, and guide-path segments; a sealed-cross-map
negative control fails reachability as expected.

All images are unmodified viewport captures. The capture scene is the actual
new scene in isolation, not the full six-addon application host. There is no
combat, player locomotion, live loot, extraction settlement or human approval
claim. Source policy registration is additive; the pre-existing unregistered AI
entrypoints on the current main baseline are outside this change.
