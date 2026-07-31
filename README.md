# cyscale

[![Build Status](https://img.shields.io/github/actions/workflow/status/thewhaleking/cyscale/unittests.yml?branch=master)](https://github.com/thewhaleking/cyscale/actions/workflows/unittests.yml?query=workflow%3A%22Run+unit+tests%22)
[![Latest Version](https://img.shields.io/pypi/v/cyscale.svg)](https://pypi.org/project/cyscale/)
[![Supported Python versions](https://img.shields.io/pypi/pyversions/cyscale.svg)](https://pypi.org/project/cyscale/)
[![License](https://img.shields.io/pypi/l/cyscale.svg)](https://github.com/thewhaleking/cy-scale-codec/blob/master/LICENSE)

Cython-accelerated [SCALE codec](https://docs.substrate.io/reference/scale-codec/) library for Substrate-based blockchains (Polkadot, Kusama, Bittensor, etc.), with no external runtime dependencies.

Originally a drop-in replacement for [py-scale-codec](https://github.com/polkascan/py-scale-codec) — same `scalecodec` module name, compiled with Cython — cyscale has since diverged and is **no longer drop-in compatible**: its decode paths produce plain Python values (`int`/`str`/`bool`/`dict`/`list`/`tuple`/`None`) directly instead of building `ScaleType` object trees. See [Compatibility with py-scale-codec](#compatibility-with-py-scale-codec).

## Installation

```bash
pip install cyscale
```

## Compatibility with py-scale-codec

cyscale keeps py-scale-codec's module name and most of its API surface, but it
is not a drop-in replacement anymore. What diverges:

- **Plain values, not ScaleTypes.** The optimized decode paths — a compiled
  per-type *value decoder* used by `batch_decode`, `get_value_decoder`, and
  the extrinsic/call/event fast paths — decode straight to plain Python
  values. The shapes match what `.value` (`value_serialized`) always
  contained; what's gone is the per-node `ScaleType` object tree around them.
  Consumers should work with the returned values directly rather than
  expecting `.value` / `.value_object` wrappers.
- **`value_object` fidelity is not guaranteed on fast-pathed types.** Where a
  wrapper object still exists (e.g. a decoded `GenericExtrinsic`), its
  `value_object` may hold plain data instead of nested `ScaleType` instances.
- **Nested `call_hash` is corrected.** py-scale-codec computes the hash of a
  call nested inside `batch`/`sudo`/`proxy` over the call's bytes *plus
  everything after it* in the buffer (a `get_used_bytes()`-mid-decode bug).
  cyscale hashes exactly the call's own bytes, so nested `call_hash` values
  intentionally differ.

The classic object API (`create_scale_object(...)` / `.decode()` /
`.encode()`) still exists and remains the fallback for types the value
decoder does not cover, so encode paths and exotic types behave as before.

## Performance

Benchmarked on Apple M-series (Python 3.13) against py-scale-codec 1.2.12.
All timings are µs per call; speedup = py ÷ cy.

### Primitives and small types

| Benchmark                                    |  py (µs) |  cy (µs) | speedup |
|----------------------------------------------|---------:|---------:|--------:|
| u8 decode                                    |     3.01 |     1.69 |   1.78× |
| u16 decode                                   |     2.99 |     1.80 |   1.66× |
| u32 decode                                   |     3.11 |     1.83 |   1.70× |
| u64 decode                                   |     3.09 |     1.79 |   1.73× |
| u128 decode                                  |     2.91 |     1.84 |   1.58× |
| Compact<u32> decode                          |     9.59 |     6.90 |   1.39× |
| bool decode                                  |     2.93 |     1.61 |   1.82× |
| H256 decode                                  |     2.93 |     1.66 |   1.76× |
| AccountId decode (SS58 format 42)            |    11.45 |     4.31 |   2.66× |
| Str decode                                   |    12.89 |     8.58 |   1.50× |
| (u32, u64, bool) decode                      |    21.96 |     8.36 |   2.63× |
| u32 encode                                   |     2.34 |     1.50 |   1.57× |
| u64 encode                                   |     2.33 |     1.55 |   1.50× |
| Compact<u32> encode                          |     8.85 |     6.36 |   1.39× |
| H256 encode                                  |     2.47 |     1.42 |   1.74× |
### Large payloads

| Benchmark                                       |   py (µs) |   cy (µs) |   speedup |
|-------------------------------------------------|----------:|----------:|----------:|
| Vec<u32> decode (64 elements)                   |    224.20 |     20.88 |    10.74× |
| Vec<u32> decode (1,024 elements)                |   3217.32 |    147.21 |    21.85× |
| Vec<u32> decode (16,384 elements)               |  50396.95 |   2150.86 |    23.43× |
| Bytes decode (1 KB)                             |     14.67 |      9.99 |     1.47× |
| Bytes decode (64 KB)                            |     64.15 |     63.30 |     1.01× |
| Bytes decode (512 KB)                           |    379.99 |    429.74 |     0.88× |
| Vec<EventRecord> decode (5 events, V10)         |    301.10 |    131.81 |     2.28× |
| MetadataVersioned decode (V10, 85 KB)           |  64958.83 |  35936.30 |     1.81× |
| MetadataVersioned decode (V13, 219 KB)          | 143029.99 |  81044.60 |     1.76× |
| MetadataVersioned decode (V14, 300 KB)          | 390902.34 | 185823.12 |     2.10× |
| Bittensor metadata + portable registry (254 KB) | 443089.47 | 211343.83 |     2.10× |

Primitives and small types see **~2.0–2.6× speedup**. Large metadata decoding
sees **~2.1–2.3× speedup** — the gain compounds across thousands of recursive
decode calls. Raw bulk byte operations (`Bytes`/`Vec<u8>`) above ~64 KB are
dominated by `memcpy` and see a reduced **~1.3–1.4× speedup**.

`AccountId` with SS58 encoding shows a **1.87× speedup** — the SS58 encoding
itself (`ss58_encode`) is pure Python and limits gains in that path.

### batch_decode (cyscale-only API)

`batch_decode(type_strings, bytes_list)` amortises Python dispatch overhead
across a list of decodes. The baseline below is a py-scale-codec decode loop,
which is the equivalent operation without this API.
Note: `bt_decode` is excluded from this comparison because it does not perform
SS58 encoding — including it without that post-processing step would be unfair.

| Benchmark                        | py loop (µs) | cy batch (µs) |   speedup |
|----------------------------------|-------------:|--------------:|----------:|
| batch_decode AccountId ×10       |       116.66 |         19.36 |     6.03× |
| batch_decode AccountId ×100      |      1159.47 |        190.19 |     6.10× |
| batch_decode AccountId ×1,000    |     11530.59 |       1888.99 |     6.10× |
| Mixed (AccountId/u32/u128) ×100  |       599.73 |         71.42 |     8.40× |

To reproduce, run:

```bash
# save a py-scale-codec baseline
python benchmarks/bench.py --save-baseline benchmarks/baseline_py.json

# compare against cy-scale-codec
PYTHONPATH=. python benchmarks/bench.py --compare benchmarks/baseline_py.json
```

## Examples of different types

| Type           | Description                                                                                                                                                                    | Example SCALE decoding value                         | SCALE encoded value            |
|----------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------|--------------------------------|
| `bool`         | Boolean values are encoded using the least significant bit of a single byte.                                                                                                   | `True`                                               | `0x01`                         |
| `u16`          | Basic integers are encoded using a fixed-width little-endian (LE) format.                                                                                                      | `42`                                                 | `0x2a00`                       |
| `Compact`      | A "compact" or general integer encoding is sufficient for encoding large integers (up to 2\*\*536) and is more efficient at encoding most values than the fixed-width version. | `1`                                                  | `0x04`                         |
| `Vec`          | A collection of same-typed values is encoded, prefixed with a compact encoding of the number of items, followed by each item's encoding concatenated in turn.                  | `[4, 8, 15, 16, 23, 42]`                             | `0x18040008000f00100017002a00` |
| `str`, `Bytes` | Strings are Vectors of bytes (`Vec<u8>`) containing a valid UTF8 sequence.                                                                                                     | `"Test"`                                             | `0x1054657374`                 |
| `AccountId`    | An [SS58 formatted](https://docs.substrate.io/reference/address-formats/) representation of an account.                                                                        | `"5GDyPHLVHcQYPTWfygtPYeogQjyZy7J9fsi4brPhgEFq4pcv"` | `0xb80269ec...`                |
| `Enum`         | A fixed number of variants, each mutually exclusive. Encoded as the first byte identifying the index of the variant.                                                           | `{'Int': 8}`                                         | `0x002a`                       |
| `Struct`       | For structures, values are named but that is irrelevant for the encoding (only order matters).                                                                                 | `{"votes": [...], "id": 4}`                          | `0x04b80269...`                |

## Development

Day-to-day tasks are wrapped in `./dev.sh` (plain POSIX shell; the only tools
it uses are `uv` and `git`):

```bash
./dev.sh build        # regenerate .c for changed .pyx and build extensions in place
./dev.sh rebuild-all  # force-regenerate every extension, restoring diff-noise-only .c files
./dev.sh test         # run the test suite (extra args pass through to pytest)
./dev.sh bench        # run benchmarks/bench.py (extra args pass through)
```

The generated `.c` files are committed, so installing from sdist needs no
Cython. When a `.pyx` changes, regenerate its `.c` with `./dev.sh build` and
commit both.

Two conventions the script enforces:

- **Regenerate through `setup.py`, never the standalone `cythonize` CLI.**
  `setup.py` passes relative `Extension` sources, so the Cython metadata
  embedded in the committed `.c` files stays relative
  (`"scalecodec/types.pyx"`). The `cythonize` CLI resolves inputs to absolute
  paths and would leak a local filesystem layout into the repo.
- **Only commit `.c` files whose `.pyx` actually changed.** A forced rebuild
  re-emits every `.c` with harmless Cython-output drift; `rebuild-all`
  restores any whose source is untouched in git, keeping diffs to the real
  change set.

The build targets the interpreter of the project venv (`.venv`), so
`./dev.sh test` always runs against the freshly built extensions.

## License

Apache 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
