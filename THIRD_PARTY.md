# Third-party material

What in this repository, and in the package it builds, came from somewhere
else, under what terms, and how much of it. Three kinds, and the distinction
matters for what a reader may do with each:

- **Built source**: code fetched at build time and compiled into the package.
  None of its bytes are in this repository; its licence travels with the
  package that carries it, and where it does not yet, this file says so.
- **Quoted prose**: phrases quoted with attribution inside comments and
  documents, to show where a claim came from.
- **Facts**: behaviour another project published, or that its source shows --
  a socket's line format, a preset's keys, a model's lookahead -- which this
  code relies on. Facts are cited, not copied; no code from these projects is
  in this repository.

No file here is vendored from another project. One is a change to another
project's file: `packaging/patches/0001-ladspa-hold-headroom-above-the-host-quantum.patch`,
whose context lines quote the fork's `ladspa/src/lib.rs` (next section). The
code and documents that did not start here came from JayOS, last section.

## ismailivanov/DeepFilterNetPlus (MIT OR Apache-2.0) -- built, not vendored

The plugin, `/usr/lib/ladspa/libdeep_filter_ladspa.so`, is built from
<https://github.com/ismailivanov/DeepFilterNetPlus> at commit
`d97178d739dffc9f862315cad83f79d40580dc3d`, the fork's v1.0.2 tag peeled.
That is the pin on 2026-10-03; the `_commit=` line of
`packaging/arch/PKGBUILD` is the pin whenever this is read. What is built is
one crate, `deep-filter-ladspa` (`ladspa/`), with `libDF` (the `deep_filter`
crate) under it, and the full DeepFilterNet 3 model,
`models/DeepFilterNet3_onnx.tar.gz` -- three ONNX graphs and a `config.ini`
-- embedded in the `.so` with `include_bytes!`. makepkg clones the fork and
`packaging/steps.sh` builds it, after applying `packaging/patches/` to it.

The patch is the one part of the fork in this repository: a unified diff of
`ladspa/src/lib.rs`, whose unchanged context lines -- three around each
change, as git writes them -- are the fork's code, quoted so that `git apply`
can find where each change goes. The changed lines are this package's. The
patched file is the fork's file modified, so the patch is offered on the
fork's terms, MIT OR Apache-2.0 at the user's option, as the fork's
`LICENSE` below asks of a contribution; it is not under this repository's
MIT alone. It was written on 2026-10-17 against the pin.

The fork's `LICENSE`, `LICENSE-MIT` and `LICENSE-APACHE` are installed with
the package, under `/usr/share/licenses/jayos-denoise/DeepFilterNetPlus/`
(`packaging/steps.sh`, `package`). Both crates' `Cargo.toml` say
`license = "MIT/Apache-2.0"` and `authors = ["Hendrik Schröter"]`, upstream's
author, and the fork's README credits the DeepFilterNet contributors.
Neither `models/` nor the model tarball holds a licence file of its own.
Everything in this section was read from a mirror of the fork, at that
commit, on 2026-10-03. Its `LICENSE`, verbatim:

    ## License

    Licensed under either of
     * Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
     * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
    at your option.

    ### Contribution

    Unless you explicitly state otherwise, any contribution intentionally submitted
    for inclusion in the work by you, as defined in the Apache-2.0 license, shall
    be dual licensed as above, without any additional terms or conditions.

Its `LICENSE-MIT`, verbatim:

    The MIT License (MIT)
    Copyright (c) 2021 Hendrik Schröter

    Permission is hereby granted, free of charge, to any person obtaining a copy of
    this software and associated documentation files (the "Software"), to deal in
    the Software without restriction, including without limitation the rights to
    use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
    the Software, and to permit persons to whom the Software is furnished to do so,
    subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
    FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
    COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
    IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
    CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Its `LICENSE-APACHE` is the Apache License, Version 2.0, 201 lines, whose
appendix is filled in as `Copyright 2021 Hendrik Schröter`. It is not
repeated here; the package installs it.

### What else is inside the `.so`, and what the package does not install

The `.so` is not only the fork's code. Run at the pin on 2026-10-03,

    cargo tree --frozen -p deep-filter-ladspa --no-default-features \
        -e normal,no-proc-macro --target x86_64-unknown-linux-gnu

names 102 packages built for the plugin: the fork's two crates, xobs'
`ladspa.rs` from git, and 99 from crates.io. The licence expressions their
manifests give, as cargo prints them:

| Licence expression | Packages |
|---|---|
| `MIT OR Apache-2.0`, `MIT/Apache-2.0` or `Apache-2.0 OR MIT` | 78, the fork's two among them |
| `MIT` | 9 |
| `Unlicense OR MIT` or `Unlicense/MIT` | 6 |
| `MIT AND (MIT OR Apache-2.0)` (`libm`) | 1 |
| `Apache-2.0` (`prost` 0.11.9) | 1 |
| `Unlicense` (`ladspa` 0.3.5, xobs' `ladspa.rs`, the LADSPA binding) | 1 |
| MIT or Apache-2.0 among other choices: `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` (2), `MIT OR Zlib OR Apache-2.0`, `BlueOak-1.0.0 OR MIT OR Apache-2.0`, `BSD-2-Clause OR Apache-2.0 OR MIT`, `0BSD OR MIT OR Apache-2.0` | 6 |

None is copyleft. One of them, `jemalloc-sys` 0.5.4, also compiles
jemalloc's own C source, whose `COPYING` (Jason Evans, the Mozilla
Foundation, Facebook) is a two-clause BSD licence.

**The package installs none of those notices** -- only the fork's three files
and this repository's own `LICENSE` and this file. Most of those licences ask
that their notice go with a binary: MIT's "shall be included in all copies or
substantial portions of the Software", and jemalloc's second clause, which
asks a binary redistribution to reproduce it "in the documentation and/or
other materials provided with the distribution". So a package built here and
given to someone else does not carry everything it should. JayOS's
`deepfilternet-ladspa` recipe, which this package replaces, installed the
same three files and no others. This is a known gap, not a decision.

## Rikorose/DeepFilterNet (MIT OR Apache-2.0) -- the upstream, cited

The project the fork is a fork of: <https://github.com/Rikorose/DeepFilterNet>.
Its `LICENSE` is byte for byte the fork's, MIT or Apache-2.0 at your option,
and its `LICENSE-MIT` names Hendrik Schröter, 2021 -- both read on its main
branch on 2026-10-03. The models, `libDF` and the LADSPA crate are its
work, and reach this package through the fork's tree, under the fork's
licence files above. `docs/DEEPFILTERNET.md` cites it for facts: its release
and commit dates, its plugin's blocking real-time callback and issue #661,
and the paper behind the model (Schröter et al.).

## Facts and quoted prose from other projects (no code copied)

| Project | Licence | What is cited or quoted |
|---|---|---|
| [wwmm/easyeffects](https://github.com/wwmm/easyeffects) | GPL-3.0-or-later: `LICENSE` at v8.2.9 is the GPL version 3, and `src/local_server.cpp`'s header at v8.2.9 says "either version 3 of the License, or (at your option) any later version" (both read on 2026-10-03) | Facts, each cited where it is used, mostly in `src/easyeffects-lib.sh` and `docs/DEEPFILTERNET.md`: the socket's path and line format, what each line is answered with and from which version, the 8.x layout of presets and settings, the preset's keys and plugin index, the LADSPA search list, the control ports' ranges. Two quoted phrases: "does not seem to destroy its threads properly", from `src/deepfilternet.cpp:97` at v8.2.9 (in `src/jayos-denoise` and `docs/DEEPFILTERNET.md`), and "active only when our window is opened", from `src/contents/kcfg/easyeffects_db.kcfg:51` at v8.2.9 (in `src/easyeffects-lib.sh`). `tests/shell/test-engine.sh`'s fake daemon is modelled on `src/local_server.cpp`, not copied from it. |
| [ismailivanov/DeepFilterNetPlus](https://github.com/ismailivanov/DeepFilterNetPlus) | MIT OR Apache-2.0, above | Beyond what is built: its `docs/LADSPA_OVERLOAD_REPORT.md`, for why upstream's plugin can stall, and its plugin's log line "Output underrun, increasing processing latency" (`ladspa/src/lib.rs:543` at the pin) |

## Jadocee/jayos -- where this repository's code came from

`src/jayos-denoise`, `src/easyeffects-lib.sh`, the cases and fakes in
`tests/shell/test-engine.sh`, and everything in `docs/DEEPFILTERNET.md` after
its preface came from <https://github.com/Jadocee/jayos> at commit `bf53d6a`,
where they were `config/common/scripts/hypr/denoise.sh`,
`config/common/scripts/easyeffects-lib.sh`, `tools/test-easyeffects.sh` and
`docs/AUDIO.md`; each file's header, or the document's preface, names what it
was and what changed. JayOS is Jadocee's, as this repository is, so this is a
move, not a borrowing: the copies here are under this repository's MIT
licence, `LICENSE`. jayos itself has no licence file at its root at that
commit, so nothing here says what terms jayos's own copies are under.
