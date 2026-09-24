# Contributing

Bug reports and fixes are welcome: open an issue or a pull request on
[GitHub](https://github.com/bettse/voxelnative).

## Licensing of contributions

VoxelNative is dual licensed under the
[GNU LGPL v2.1 or later](LICENSE-LGPL) or the [MIT license](LICENSE-MIT), at
your option (SPDX: `LGPL-2.1-or-later OR MIT`).

By submitting a contribution (a pull request, patch, or any code you intend to
be included), you agree that it is licensed under **both** of those licenses,
the same as the rest of the project, and that you have the right to license it
that way. The MIT side is what lets the app ship on the App Store, so a
contribution that can only be LGPL can't be merged.

That means: don't port or copy code from the Luanti engine (or any other
LGPL/GPL source) into a contribution. Reading the engine to learn how the
protocol or a behavior works is fine, and so is matching that behavior; write
the code yourself. If you're unsure whether something counts, say so in the PR
and we'll sort it out.

## Before you open a PR

- Build with `native/sim.sh` and run `native/simtests.sh` (it drives the
  visionOS simulator against a local dev server).
- Keep comments about the *why*; the code already says the what.
