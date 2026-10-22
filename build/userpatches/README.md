# userpatches

Copied into the pinned Armbian framework as `userpatches/` before each build
(see `scripts/build-image.sh`). This is Armbian's supported extension point:

- `customize-image.sh` — runs inside the image chroot at the end of the build;
- `overlay/` — files available in the chroot as `/tmp/overlay`.

Step 1 builds a plain Armbian Trixie minimal image, so nothing is customized
yet. Later steps add our services here.
