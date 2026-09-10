# Linux x86_64 headless server artifact report

Status: **BLOCKED** as of 2026-09-09.

The six locked add-ons declare Linux x86_64 debug libraries, but none of the
declared shared objects are present in the vendored packages. This is the
earliest exact blocker: a headless Godot process cannot load the combined
extension set until all six native artifacts are supplied from their locked
source revisions.

Reproduce from the project root:

```sh
python3 tools/check_platform_artifacts.py linux-debug-server
```

Expected result: six `MISSING` records and
`status=BLOCKED` with process exit code 2. The report derives each required path
from the package's `.gdextension` descriptor rather than maintaining a second
hand-written list.

Once all six shared objects exist, run this check again, create a minimal Linux
headless debug export with all six plugins enabled, and run the combined add-on
smoke on a Linux x86_64 host. Until that target-native load succeeds, Linux
headless hosting is not a supported Zerkov build target.
