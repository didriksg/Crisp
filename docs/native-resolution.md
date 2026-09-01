# Native panel resolution

Crisp needs the physical panel dimensions to filter mode families and build the
smooth-scaling ladder. The current desktop mode and macOS's `native` mode flag are
not reliable inputs: after a bad link negotiation or another display override,
WindowServer can mark a compatibility timing such as 1024×768 as native even though
the connected panel is 3840×2160.

Resolution inference therefore uses this order:

1. A per-display manual panel-resolution override, when the user set one.
2. The preferred/native detailed timing from a checksum-valid EDID.
3. `NativeFormatHorizontalPixels` and `NativeFormatVerticalPixels` from Apple's
   EDID-derived display metadata (the raw EDID is often unavailable through DCP on
   Apple Silicon).
4. The largest unscaled mode, retained as a compatibility fallback.
5. The current pixel dimensions if no other evidence exists.

Manual values are stored by vendor, product, and serial identity and are always
entered in the panel's unrotated space. They can be changed or reset under
Resolution > Native resolution. Changing the value does not silently rewrite an
installed `/Library/Displays` override; the Smooth scaling switch reflects that the
old grid no longer matches, and enabling it writes the corrected grid through the
normal administrator-authorized flow.

On Apple Silicon, smooth-scaling entries are limited to a 6720-pixel backing width,
matching the current WindowServer/DCP limit. A 3840×2160 panel therefore receives a
dense 16:9 HiDPI ladder from 1920×1080 through 3360×1890, including 2560×1440 and
2880×1620, plus the real 3840×2160 1× native endpoint.
