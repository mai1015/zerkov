# Windows x86_64 debug client artifact report

Status: **BLOCKED** as of 2026-09-09.

The six locked add-ons declare Windows x86_64 debug libraries, but none of the
declared DLLs are present in the vendored packages. This is the earliest exact
blocker: Godot cannot load or export the combined extension set until all six
native artifacts are supplied from their locked source revisions.

Reproduce from the project root:

```sh
python3 tools/check_platform_artifacts.py windows-debug-client
```

Expected result: six `MISSING` records and
`status=BLOCKED` with process exit code 2. The report derives each required path
from the package's `.gdextension` descriptor rather than maintaining a second
hand-written list.

Once all six DLLs exist, run this check again, create a minimal Windows debug
export with all six plugins enabled, and run the combined add-on smoke on a
Windows x86_64 host. Until that target-native load succeeds, Windows is not a
supported Zerkov build target.
