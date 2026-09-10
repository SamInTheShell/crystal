# wasm32-wasi target: plan and status

Working notes for turning `wasm32-unknown-wasi` into a fully usable target.
Read this at the start of every session, update it at the end. Branch:
`wasm32-target` (off master `8dec18f96`, 2026-09-09).

## Environment / budget (measured 2026-09-10, 32 cores)

| Step | Time |
| --- | --- |
| `make crystal` (must run with `CRYSTAL_LIBRARY_PATH` **unset**, see gotchas) | 38 s |
| `bin/crystal build spec/wasm32_std_spec.cr --target wasm32-wasi ...` | 22 s |
| `wasmtime run wasm32_std_spec.wasm` | 2 s |
| Per-spec sweep of all disabled specs (6 parallel builds) | ~1.5 min |
| `scripts/wasm32/build-libs.sh` (zlib+gmp+libyaml+libxml2) | ~1 min |

Reference build command (CI):

```
bin/crystal build spec/wasm32_std_spec.cr -o wasm32_std_spec.wasm --target wasm32-wasi \
  -Dwithout_iconv -Dwithout_openssl -Dwithout_zlib -Dwithout_mt
wasmtime run wasm32_std_spec.wasm
```

Local "everything" build (needs libs built by `scripts/wasm32/build-libs.sh --prefix DIR`):

```
CRYSTAL_LIBRARY_PATH=/opt/wasm32-wasi-libs:DIR/lib bin/crystal build spec/wasm32_std_spec.cr \
  -o out.wasm --target wasm32-wasi -Dwithout_iconv -Dwithout_openssl -Dwithout_mt
wasmtime run --dir . out.wasm        # from the repo root; specs read spec/std/data
```

### Gotchas

* `CRYSTAL_LIBRARY_PATH=/opt/wasm32-wasi-libs` is exported globally in the
  container. Native builds (`make crystal`, native `bin/crystal spec`) pick
  up the wasm `libgc.a` and fail to link. Prefix them with
  `env -u CRYSTAL_LIBRARY_PATH`.
* The same problem hits **macro `run`** during a wasm build: the macro
  program is compiled natively but links with `-L$CRYSTAL_LIBRARY_PATH`,
  finds the wasm `libgc.a`, and fails. This breaks every spec that uses ECR
  (`spec/std/http/spec_helper.cr`) under cross-compilation. Needs a compiler
  fix or a documented workaround; see open questions.
* The repo was root-owned; `sudo chown -R dev:dev /work/crystal` was needed.

## Progress metric: `spec/wasm32_std_spec.cr`

| | enabled `require` | disabled (`# require`) | examples (CI flags) |
| --- | --- | --- | --- |
| master | 101 | 164 (6 of them stale paths) | 7056 |
| 2026-09-10 | 180 | 120 | 11145 |

The harness now lists every `spec/std/**/*_spec.cr` (300 files; 41 were
never listed on master). Library-dependent specs are guarded with
`without_zlib` / `without_gmp` / `without_yaml` / `without_libxml2`; CI passes
all four (its tarball has none of those libs), local runs with the libs
built by `scripts/wasm32/build-libs.sh` pass none.

Last full-harness runs on this branch (0 failures in both):

* CI mode (all `without_*` flags, CI tarball libs): 11145 examples.
* Full mode (local libs, no `without_*`, `wasmtime run --dir .`): 13110 examples.

### Sweep results (2026-09-10, after the fixes below, old CI tarball libc + local zlib)

All 164 originally disabled specs and 41 specs that were never listed were
rebuilt and run individually. Classification:

* **PASS (49)**: `string_spec` (1062 examples!), `char_spec`, all
  `compress/*`, `digest/adler32|crc32`, `crystal/digest/*`, `env`, `errno`,
  `http/client/response`, `http/cookie(s)`, `http/formdata/builder`,
  `http/status`, `ini`, `io/argf|buffered|multi_writer|prefix_suffix_buffer`,
  `log/*` (broadcast, log, metadata, spec), `mime*`, `spec/context|filters`,
  `system_error`, `file/match*`, `float_printer/hexfloat|shortest`,
  `crystal/event_loop/timers`, `crystal/lru_cache`, `pointer_pairing_heap`,
  `cpucount`, `fiber/list`, `pointer/appender`, `process/exit_reason|utils`,
  `uri/json`, `uri/params/*`, `math_spec` (after scalbln fix),
  `time/format|location|time`, `benchmark`, `time/instant` (after sleep).
  All enabled in the harness.
* **Link failures**: gmp (12 specs), libyaml (10), libxml2 (7) → fixed by
  `scripts/wasm32/build-libs.sh`; 23 of those 29 pass now (enabled behind
  flag guards), the other 6 are `expect_raises` (EH) or `System.hostname`
  (junit formatter; no WASI API). `llvm/*` need libLLVM: out of scope.
* **Codegen failures**:
  * `expect_raises` returns `Nil` because `raise` is `NoReturn`/exit on
    wasm32 → "undefined method 'os_error' for Nil" etc. (~10 specs). **EH,
    workstream 4a.**
  * `without_openssl` (12 specs): expected, stay disabled.
  * `Process.spawn`/`prepare_args` (9 specs): no processes in WASI.
  * `Thread#init_handle` (3): no threads.
  * `Signal::INT` (`process/status_spec`): no signals.
  * ECR macro `run` (7 `http/server/*` specs): the gotcha above.
* **Run failures**:
  * `FATAL: can't resume a running fiber` — channel, concurrent, select,
    mutex, sync/*, crystal/lock, fd_lock, wait_group, log/context:
    **fibers, 4b.**
  * `create_timeout_event` NotImplemented (fiber_spec, wait_group): 4b/3.
  * `Expected 0 to be GreaterThan 0` (object, reference, weak_ref,
    log/builder): `GC.stats` with `gc_none`: **GC, 4c.**
  * `EventLoop::Wasi#pipe` (io/hexdump, io/stapled): WASI p1 has no pipes.
  * `File.chmod` (process/find_executable), User/Group lookups: no WASI API.
  * `io/memory_spec`: allocates `Int32::MAX` bytes and expects a raise → EH.
  * `json/pull_parser_spec`: `OverflowError` expected by spec → EH.
  * `file/tempfile_spec`: expects POSIX permission bits, WASI returns none.
    Needs `pending_wasm32` in the spec.
  * `crystal/system_spec` `%p` with `UInt64::MAX`: 32-bit pointer, spec
    assumes 64-bit.
  * `http/chunked_content_spec`, `log/dispatch`, `log/io_backend`,
    `sync/mutex`: not yet analysed (likely fibers or EH).

## Workstream status

### 1. Linking failures — done for zlib/gmp/libyaml/libxml2; tarball decision pending

* `scripts/wasm32/build-libs.sh` cross-builds **zlib 1.3.1, gmp 6.3.0,
  libyaml 0.2.5, libxml2 2.13.8** with wasi-sdk (pinned SHA-256s, output in
  `PREFIX/lib`). Recipes notes: gmp needs `-D_WASI_EMULATED_SIGNAL` +
  `ac_cv_func_raise=yes` (and `LibGMP` links `wasi-emulated-signal` on
  wasm32); libyaml needs wasi-sdk's `config.sub`; libxml2 needs a `dup()`
  shim (no `dup` in WASI).
* Binding fixes found by wasm-ld signature checks (wasm enforces exact
  signatures, native ABIs silently tolerate these):
  `LibZ.adler32_combine/crc32_combine` (`z_off_t` is 64-bit on wasi),
  `LibM.scalbln` (`long` is 32-bit), `LibGMP.*div_*_ui` (return `unsigned
  long`, were declared void).
* Library specs enabled behind `without_zlib`/`without_gmp`/`without_yaml`/
  `without_libxml2` guards; CI passes all four (old tarball) and stays green.
* `LibXML::VERSION` on wasm32 is read from `lib/libxml_VERSION` (written by
  the script) because the host's pkg-config reported 2.9.14 and the binding
  then used the wrong (pre-2.13) error-handling API against 2.13.8.
* **Not done**: pcre2 and bdwgc recipes (so the script can produce the
  *whole* library dir, replacing lbguilherme's tarball). pcre2 10.45 builds
  fine with autotools (`--disable-jit`). bdwgc 8.2.x has no WASI support
  (only Emscripten); master does. lbguilherme/wasm-libs has `libs/libgc/
  build.sh` to crib from.

### 2. Codegen failures — root causes identified

The 14 "failed codegen" entries were: stale requires (`io/evented`, fixed),
outdated event-loop signatures (fixed), 6 stale paths (spec files moved:
`float_printer/*`, `llvm/*`, `oauth/params`), and `expect_raises` → `Nil`
(EH). `json/serializable` and YAML serialization specs are in the
`expect_raises` bucket, not an ABI problem. `src/llvm/abi/wasm32.cr` was not
implicated.

### 3. WASI event loop — partially done

Implemented: `open`, `sleep` (blocking `nanosleep`; fine while there is a
single fiber). Still `NotImplementedError`: `run`, `interrupt`,
`create_timeout_event`, `pipe` (impossible in WASI p1), all `wait_*`
(need `poll_oneoff`). Do the `poll_oneoff` loop once 4b exists to make it
observable.

### 4. Runtime — unblocked (decisions below), nothing implemented yet

Nothing started. Related fixes done on the way: wasm32 libc constants
(`AT_FDCWD`, `AT_*`, `R_OK`/`X_OK`), `File.delete/utime`, `FileDescriptor`
blocking mode, `Socket`/`Addrinfo` compile again.

## 4a gate: Binaryen Asyncify vs wasm EH (answered 2026-09-10)

Tested with Binaryen 132 (`wasm-opt`), wasmtime 48, node 22 (V8 12.4),
LLVM 18 clang.

| | legacy EH (`try`/`catch`/`delegate`) | standardized EH (`try_table`/exnref) |
| --- | --- | --- |
| `wasm-opt --asyncify` | **works**; unwind/rewind through a `try` body verified end-to-end | **crashes** (`UNREACHABLE at Flatten.cpp:231`) |
| LLVM 18 `-fwasm-exceptions` | emits this (only option; no `-wasm-use-legacy-eh=false` yet) | not available before LLVM 19/20 |
| wasmtime 48 (`-W exceptions`) | rejected (`legacy_exceptions feature required`) | runs |
| node 22 / V8 | runs | runs (also with `--experimental-wasm-exnref`) |
| `wasm-opt --translate-to-exnref` | converts legacy → exnref; the *asyncified* legacy module translated this way runs correctly in node | |

Conclusion: **native wasm EH and Asyncify do compose**, but only in this
order: LLVM emits legacy EH → `wasm-opt --asyncify` → (optionally)
`wasm-opt --translate-to-exnref` for runtimes that only accept the
standardized form (wasmtime, future browsers). Browsers currently accept
both forms. The pipeline is a post-link `wasm-opt` step that Crystal must
run for wasm32 (gated; Binaryen becomes a wasm32-only build dependency).

Codegen side: clang emits `personality @__gxx_wasm_personality_v0`,
`catchswitch`/`catchpad` (the same funclet IR shape as the MSVC path) and
the `__cpp_exception` tag. Crystal's `__crystal_personality` would have to
be named `__gxx_wasm_personality_v0` (LLVM classifies the EH scheme by
personality name, same trick as `__CxxFrameHandler3` on MSVC), and the
runtime needs a small `_Unwind_CallPersonality`/`__wasm_lpad_context`
shim (libunwind's `Unwind-wasm.c` is ~100 lines). LLVM also needs
`-wasm-enable-eh` (a `cl::opt`; Crystal already has
`LLVM.parse_command_line_options`) and `-exception-model=wasm`.

**Decision (2026-09-10): native EH** (legacy form + Asyncify + translate
pass); see Decisions below. wasi-sdk 33 ships the runtime side already:
`share/wasi-sysroot/lib/wasm32-wasip1/eh/libunwind.a` exports
`_Unwind_CallPersonality`/`_Unwind_RaiseException`, and its `libc++abi.a`
has `__gxx_personality_wasm0`.

## Commits on this branch (oldest first)

1. Implement `Crystal::EventLoop::Wasi#open`
2. Implement `File.delete`, `File.utime` and blocking mode on wasm32-wasi
3. Add zlib support for wasm32-wasi (script, `LibZ` fix, specs enabled)
4. Fix compilation of `Socket` on wasm32-wasi
5. Fix `Math.scalbln` on 32-bit targets
6. Fix `AT_*` and `*_OK` constants in the wasm32-wasi libc bindings
7. Implement `Crystal::EventLoop::Wasi#sleep`
8. Add gmp, libyaml and libxml2 support for wasm32-wasi
9. Update the wasm32 spec harness (180 enabled / 120 disabled, CI flags,
   `--dir .`)
10. This file.

Shared (non-wasm-gated) code touched, all verified with native specs
(2196 examples, 0 failures): `Math.scalbln` (`LibC::Long` + clamp, no-op on
64-bit), `LibGMP` return types (ignored on native), `big_float_spec`
32-bit guard, `spec/wasm32_std_spec.cr`, CI workflow.

## Upstream recon (2026-09-10)

Sources: crystal-lang/crystal #12002 (roadmap), #13130 (exceptions,
`status:discussion`), #13107 (Asyncify fibers PR, approved by
straight-shoota, never merged), #11931 (bundling wasm tooling), #11941/#11935
(wasm exports/imports), #10870 (platform-port PR etiquette),
CONTRIBUTING.md, forum threads 4522/4709/5132, `.github/workflows/*`.

What the maintainers have said, condensed:

* **Gatekeepers**: straight-shoota (compiler/CI), ysbaddaden (runtime,
  fibers, event loop; owns the 2025-26 WASI event-loop refactors),
  HertzDevil (codegen). Two Core Team approvals per PR. All prior wasm work
  is lbguilherme's and has been unmaintained since 2023.
* **Tooling**: requiring `wasm-opt` on the host for wasm builds is fine;
  *shipping* it in Crystal packages is not ("we don't ship linkers ... for
  native toolchains either", #11931). #13107 shelled out to `wasm-opt` from
  `compiler.cr` and was approved.
* **Exceptions** (#13130): 2023 leaned to an Asyncify-based rewrite because
  LLVM wasm EH was unusable then. Since 2025 the sentiment is native EH:
  HertzDevil points at LLVM 20's standardized EH, ysbaddaden researched
  Rust's approach (personality shim + `llvm.wasm.throw`), straight-shoota
  notes WASM 3.0 ships EH. Nobody wants setjmp-style.
* **Fibers**: Asyncify is the accepted approach (#13107). Nobody asked to
  wait for stack switching / JSPI.
* **GC**: roadmap assumed Boehm + Asyncify; ysbaddaden has floated a small
  native mark & sweep GC "since there's no concurrency". Wasm-GC (typed
  structs) has no maintainer support.
* **Browser / JS interop**: belongs in shards (crystal-js), not the
  compiler or stdlib. Export/import mechanism is settled: top-level `fun`
  are exported, `@[Link(wasm_import_module:)]` imports.
* **Prebuilt libs**: upstream does not want more package maintainership.
  Windows precedent: third-party libs are built *in CI* from pinned
  versions (`etc/win-ci/*.ps1`, `win_build_libs.yml`) and stored with
  `actions/cache`, never hosted as release assets.
* **LLVM**: floor is 8, CI tests 13-22, wasm CI pins 18. A feature that
  needs a newer LLVM must be gated, not required.
* **PR shape**: small, focused, issue first, no long-running platform
  branch (maxfierke on #10870), stubs carry `NotImplementedError`, enable
  every spec that passes in the same PR, no force-push, merge master not
  rebase, `crystal tool format`.
* **What users ask for**: serverless/edge functions (Shopify, Cloudflare,
  Fermyon), plugins, calling Crystal from Ruby/Node/Python, browser apps.
  Community mood is "another abandoned wasm effort"; a working, CI-tested
  slice is what changes that.
* **`wasm32-wasip1`**: never discussed upstream.

## Parity target: what Go and C++ have that Crystal on wasm lacks

| Capability | Go (`wasip1`, `js/wasm`) | C++ (wasi-sdk / Emscripten) | Crystal today | Plan |
| --- | --- | --- | --- | --- |
| Exceptions / panic-recover | yes | yes (wasm EH, `eh` sysroot) | `raise` exits | 4a |
| Green threads / coroutines | goroutines (own scheduler) | Asyncify / Fibers (Emscripten) | single fiber | 4b |
| Garbage collection | own GC | Boehm via Emscripten | `gc_none` (leaks) | 4c |
| Timers, select, channels | yes | n/a | NotImplemented | 3 + 4b |
| Files, dirs, clocks, random, env, args | yes | yes | yes | done |
| Sockets | wasip1 `sock_accept` only | same | compiles, untested | later |
| Threads | no (`js/wasm`), no (`wasip1`) | `wasm32-wasip1-threads`, pthreads | no (`without_mt`) | out of scope, same as Go |
| Processes, signals, users | no | no | no | out of scope |
| Browser: JS interop | `syscall/js` in stdlib | embind / ccall | shard (crystal-js, stale) | 5, shard-side |
| Browser: run at all | `wasm_exec.js` | Emscripten JS glue | needs a WASI shim | 5 |
| C libraries (zlib, gmp, ...) | pure Go | wasi-sdk | built by `scripts/wasm32/build-libs.sh` | 1 |
| Backtraces on error | yes | yes | no | 4a follow-up |

"Feature complete" therefore means: 4a, 4b, 4c, 3, the CI libs pipeline,
and a browser proof (module runs in node/browser through a WASI shim, with
a JS-interop shard as the documented path). Threads and processes are out,
exactly as for Go.

## Decisions (2026-09-10, after recon)

1. **Exceptions: native LLVM wasm EH**, no flag. Codegen reuses the MSVC
   funclet path (`catchswitch`/`catchpad`, funclet operand bundles) with
   personality `__gxx_wasm_personality_v0`; `raise` becomes
   `llvm.wasm.throw` with the `__cpp_exception` tag, `rescue` uses
   `llvm.wasm.get.exception` / `llvm.wasm.get.ehselector`. The runtime
   shim is wasi-sdk's `libunwind.a` (`eh` sysroot; exports
   `_Unwind_CallPersonality`, `_Unwind_RaiseException`), added to the libs
   dir. LLVM 18/19 emit the legacy `try`/`catch` form; that is required
   anyway because `wasm-opt --asyncify` only works on the legacy form. The
   post-link step then runs `--translate-to-exnref` so wasmtime and future
   browsers accept the module. On LLVM >= 20 force the legacy form
   (`-wasm-use-legacy-eh`) so the pipeline stays uniform. Matches
   ysbaddaden's Rust-style sketch and the 2025 sentiment in #13130.
   Rejected: Asyncify-only rewrite of `raise` (2023 idea, obsolete; no
   maintainer support today).
2. **Fibers: Binaryen Asyncify**, rebuilt from #13107's design (already
   approved once): `Fiber::Context` holds the Asyncify data buffer,
   `swapcontext` = unwind to the trampoline in `main`, rewind into the
   target fiber. Post-link `wasm-opt --asyncify --pass-arg=asyncify-ignore-imports`
   with the exception-handling tag/personality functions in the
   `asyncify-ignore` list as needed.
3. **Post-link `wasm-opt` step in `compiler.cr`**, next to the
   `run_dsymutil` precedent, gated on `program.has_flag?("wasm32")`.
   **If `wasm-opt` is not on PATH the build still succeeds** (a warning is
   printed, fibers/EH then fail at run time with a clear message as they
   do today). This keeps every existing wasm build working and adds no
   dependency to native builds. `-Dwithout_asyncify` skips the pass.
4. **GC: Boehm first**, using the `libgc.a` recipe from lbguilherme
   (bdwgc master has WASI support). Stack scanning of wasm locals uses an
   Asyncify unwind at collection time (Emscripten's
   `emscripten_scan_registers` trick). A native Crystal mark & sweep GC
   (ysbaddaden's idea) can replace it later behind the same `GC` API
   without touching codegen; it is a separate RFC.
5. **Libs: build in CI, cache with `actions/cache`**, exactly like
   Windows. `scripts/wasm32/build-libs.sh` gains pcre2, bdwgc and a
   `libunwind` copy; wasi-libc, clang_rt and libunwind come from the
   pinned wasi-sdk release tarball, which replaces the lbguilherme tarball
   download. No new hosting, no crystal-lang release assets.
6. **Linker: use wasi-sdk's `wasm-ld`** (LLD 22) on CI by putting
   `$WASI_SDK_PATH/bin` on PATH; Crystal codegen stays on LLVM 18. wasi-sdk
   33's libc needs wasm-ld >= 20, and the object format is stable across
   versions (full harness verified). No LLVM bump for Crystal.
7. **Binaryen on CI** comes from the pinned GitHub release
   (`version_132`; noble packages 108, which lacks `--translate-to-exnref`).
   **wasmtime on CI** must move from 2.0.0 to a release with `-W
   exceptions` (48 verified). Both are the same class of dependency as the
   existing wasmtime/LLVM downloads.
8. **`wasm32-wasip1`**: keep `wasm32-unknown-wasi` as the documented
   target. Make `flag?(:wasi)` true for any `wasi*` environment so
   `--target wasm32-wasip1` works without a rename. Raise an upstream
   issue; do not rename.
9. **Macro `run` under cross-compilation**: `codegen/link.cr:106` reads
   `CRYSTAL_LIBRARY_PATH` for *both* the target link and the host-side
   macro program. Fix: macro-run compilation ignores `CRYSTAL_LIBRARY_PATH`
   when the target differs from the host (falls back to
   `Crystal::Config.library_path`). Gated on cross-compilation only.
10. **Browser**: no compiler-side browser target. Deliver a checked-in
    example (`samples/wasm32/`?) running a Crystal module in node and a
    browser through `@bjorn3/browser_wasi_shim`, and document crystal-js
    as the interop path. Reviving crystal-js is shard work, outside this
    repo.
11. **Upstream shape**: this branch is a staging area only. Everything
    ships as small PRs (below), each preceded by a comment on the
    relevant issue (#13130 for EH, #12002 for the rest).

## PR plan (order of submission)

| # | PR | Content | Depends on |
| --- | --- | --- | --- |
| 1 | Binding fixes | `LibZ` `z_off_t`, `LibM.scalbln`, `LibGMP` return types, `LibXML` on wasm, libc `AT_*`/`*_OK` | - |
| 2 | WASI syscalls | `EventLoop::Wasi#open/#sleep`, `File.delete/utime`, blocking mode, `Socket` compile fix | - |
| 3 | Spec harness | `wasm32_std_spec.cr` regeneration, `without_*` guards, `--dir .`, `pending_wasm32` additions | 1, 2 |
| 4 | Libs in CI | `scripts/wasm32/build-libs.sh` (+pcre2, bdwgc, libunwind), wasi-sdk download, `actions/cache`, wasm-ld from wasi-sdk, wasmtime + Binaryen bumps | - |
| 5 | Compiler plumbing | post-link `wasm-opt` hook, `wasi` flag for `wasip1`, macro-run library path fix | 4 |
| 6 | Exceptions | codegen + `raise.cr` + libunwind link + specs | 5 |
| 7 | Fibers | `fiber/context/wasm32.cr`, `crystal/asyncify.cr`, scheduler hooks + specs | 5 |
| 8 | Event loop | `poll_oneoff` loop: `run`, `interrupt`, timeouts, waits + specs | 7 |
| 9 | GC | Boehm on wasm32, stack scanning via Asyncify + specs | 7 |
| 10 | Browser example | node + browser run through a WASI shim, docs | 6-9 |

## Next steps

1. Prepare PRs 1-3 from the existing commits (they are already split that
   way) and comment on #12002 with the plan; nothing in 4-10 lands
   upstream without that conversation.
2. PR 4: pcre2 + bdwgc + libunwind recipes, wasi-sdk download, cache; move
   CI to the new toolchain and verify green.
3. PR 5 plumbing, then 6 (EH) and 7 (fibers) in parallel branches off 5.
4. `spec/generate_wasm32_spec.sh` is stale; replace with a note in the
   harness header (done) or teach it the guards, in PR 3.
