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

### 4. Runtime — blocked on the gate decision (below)

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

**Decision needed (not taken):** native EH (legacy form + Asyncify +
translate pass) vs an Asyncify-only rewrite of `raise` (setjmp/longjmp-style
via Asyncify unwinding, no LLVM EH). Recommendation: native EH; it is the
path LLVM, Emscripten and the wasi-sdk `eh` sysroot already take, and the
translate pass removes the runtime-compat concern.

## Open questions for the maintainer/user

1. **Linker version.** wasi-sdk 33's `libc.a` references
   `__wasm_first_page_end`, which only wasm-ld ≥ 20 defines (wasm-ld has no
   `--defsym`). With LLD 22 (from wasi-sdk) the *full CI spec passes*
   against the new libc (7056 examples, 0 failures). Options: (a) bump CI
   to LLVM 20 and rebuild the tarball from wasi-sdk 33; (b) rebuild the
   tarball from an older wasi-sdk (≤ 24) that still works with wasm-ld 18;
   (c) keep the old libc (lacks `realpath`, `chmod`, `fchmod`).
2. **Where the libs tarball lives.** CI downloads
   `lbguilherme/wasm-libs` 0.0.3. The new script can generate a full
   replacement (once pcre2/bdwgc recipes are in). Needs a hosting decision
   (crystal-lang org release asset? a `crystal-lang/wasm-libs` repo?).
   Until then zlib/gmp/yaml/xml specs stay flag-guarded in the harness.
3. **Macro `run` under cross-compilation** picks up the target
   `CRYSTAL_LIBRARY_PATH` for the *host* link. Fix in the compiler (ignore
   `CRYSTAL_LIBRARY_PATH` for macro runs when `--target` differs from host?)
   or document a separate variable.
4. **`wasm32-wasi` → `wasm32-wasip1`** rename: wasi-sdk 33 warns on the old
   triple; the build script already uses `wasm32-wasip1` for the C libs
   (identical ABI). Crystal's target name is untouched.
5. The EH strategy above.

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

## Next steps

1. Get answers to the open questions (linker/tarball/macro-run/EH). Nothing
   in workstream 4 should start before the EH decision.
2. pcre2 + bdwgc recipes in the build script so it can produce the whole
   library directory (then the tarball question has a concrete artifact).
3. Small independent wins still available without EH/fibers:
   `pending_wasm32` for `file/tempfile_spec` permissions and
   `crystal/system_spec` `%p`; `System.hostname` on WASI (return
   "localhost"?) for `junit_formatter_spec`; `Dir`/`File` methods that the
   new libc enables (`realpath`, `chmod`).
4. `spec/generate_wasm32_spec.sh` is stale (downloads tarball 0.0.2, knows
   nothing about the guards). Either update it to take
   `CRYSTAL_LIBRARY_PATH` from the environment and emit guards, or note in
   the harness header that it is hand-maintained (done for now).
