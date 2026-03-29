# cyscale

[![Latest Version](https://img.shields.io/pypi/v/cyscale.svg)](https://pypi.org/project/cyscale/)
[![Supported Python versions](https://img.shields.io/pypi/pyversions/cyscale.svg)](https://pypi.org/project/cyscale/)
[![License](https://img.shields.io/pypi/l/cyscale.svg)](https://github.com/thewhaleking/cy-scale-codec/blob/master/LICENSE)

Cython-accelerated [SCALE codec](https://docs.substrate.io/reference/scale-codec/) library for Substrate-based blockchains (Polkadot, Kusama, Bittensor, etc.).

A drop-in replacement for [py-scale-codec](https://github.com/polkascan/py-scale-codec) — same `scalecodec` module name, same public API, compiled with Cython for improved throughput.

## Installation

```bash
pip install cyscale
```

## Performance

Benchmarked on Apple M-series (Python 3.13) against py-scale-codec 1.2.12.
All timings are µs per call; speedup = py ÷ cy.

### Primitives and small types

| Benchmark                                    | py (µs) | cy (µs) | speedup |
|----------------------------------------------|--------:|--------:|--------:|
| u8 decode                                    |    3.01 |    1.82 |  1.66×  |
| u16 decode                                   |    2.99 |    1.88 |  1.59×  |
| u32 decode                                   |    3.11 |    1.91 |  1.63×  |
| u64 decode                                   |    3.09 |    1.92 |  1.61×  |
| u128 decode                                  |    2.91 |    1.93 |  1.51×  |
| Compact\<u32\> decode                        |    9.59 |    7.20 |  1.33×  |
| bool decode                                  |    2.93 |    1.81 |  1.62×  |
| H256 decode                                  |    2.93 |    1.89 |  1.55×  |
| AccountId decode (SS58 format 42)            |   11.45 |    8.69 |  1.32×  |
| Str decode                                   |   12.89 |    9.16 |  1.41×  |
| (u32, u64, bool) decode                      |   21.96 |   17.33 |  1.27×  |
| u32 encode                                   |    2.34 |    1.87 |  1.25×  |
| u64 encode                                   |    2.33 |    1.88 |  1.24×  |
| Compact\<u32\> encode                        |    8.85 |    6.37 |  1.39×  |
| H256 encode                                  |    2.47 |    1.50 |  1.64×  |

### Large payloads

| Benchmark                                       | py (µs)    | cy (µs)    | speedup |
|-------------------------------------------------|-----------:|-----------:|--------:|
| Vec\<u32\> decode (64 elements)                 |     224.20 |     151.88 |  1.48×  |
| Vec\<u32\> decode (1,024 elements)              |   3,217.32 |   2,195.01 |  1.47×  |
| Vec\<u32\> decode (16,384 elements)             |  50,396.95 |  34,540.86 |  1.46×  |
| Bytes decode (1 KB)                             |      14.67 |      11.07 |  1.33×  |
| Bytes decode (64 KB)                            |      64.15 |      67.08 |  0.96×  |
| Bytes decode (512 KB)                           |     379.99 |     426.56 |  0.89×  |
| Vec\<EventRecord\> decode (5 events, V10)       |     301.10 |     209.99 |  1.43×  |
| MetadataVersioned decode (V10, 85 KB)           |  64,958.83 |  47,140.33 |  1.38×  |
| MetadataVersioned decode (V13, 219 KB)          | 143,029.99 | 103,979.60 |  1.38×  |
| MetadataVersioned decode (V14, 300 KB)          | 390,902.34 | 284,024.69 |  1.38×  |
| Bittensor metadata + portable registry (254 KB) | 443,089.47 | 325,681.88 |  1.36×  |

Primitives and small types see **~1.25–1.65× speedup**. Large metadata decoding
sees **~1.35–1.50× speedup** — the gain compounds across thousands of recursive
decode calls. Raw bulk byte operations (`Bytes`/`Vec<u8>`) above ~64 KB are
dominated by `memcpy` and show no meaningful difference.

`AccountId` with SS58 encoding shows a **1.32× speedup** — the SS58 encoding
itself (`ss58_encode`) is pure Python and dominates, limiting gains in that path.

### batch_decode (cyscale-only API)

`batch_decode(type_strings, bytes_list)` amortises Python dispatch overhead
across a list of decodes. The baseline below is a py-scale-codec decode loop,
which is the equivalent operation without this API.
Note: `bt_decode` is excluded from this comparison because it does not perform
SS58 encoding — including it without that post-processing step would be unfair.

| Benchmark                                       | py loop (µs) | cy batch (µs) | speedup |
|-------------------------------------------------|-------------:|--------------:|--------:|
| AccountId ×10                                   |       116.66 |         59.47 |  1.96×  |
| AccountId ×100                                  |     1,159.47 |        597.85 |  1.94×  |
| AccountId ×1,000                                |    11,530.59 |      5,943.51 |  1.94×  |
| Mixed (AccountId / u32 / u128) ×100             |       599.73 |        208.69 |  2.87×  |

To reproduce, run:

```bash
# save a py-scale-codec baseline
python benchmarks/bench.py --save-baseline benchmarks/baseline_py.json

# compare against cy-scale-codec
PYTHONPATH=. python benchmarks/bench.py --compare benchmarks/baseline_py.json
```

## Examples of different types

| Type | Description | Example SCALE decoding value | SCALE encoded value |
|------|-------------|------------------------------|---------------------|
| `bool` | Boolean values are encoded using the least significant bit of a single byte. | `True` | `0x01` |
| `u16` | Basic integers are encoded using a fixed-width little-endian (LE) format. | `42` | `0x2a00` |
| `Compact` | A "compact" or general integer encoding is sufficient for encoding large integers (up to 2\*\*536) and is more efficient at encoding most values than the fixed-width version. | `1` | `0x04` |
| `Vec` | A collection of same-typed values is encoded, prefixed with a compact encoding of the number of items, followed by each item's encoding concatenated in turn. | `[4, 8, 15, 16, 23, 42]` | `0x18040008000f00100017002a00` |
| `str`, `Bytes` | Strings are Vectors of bytes (`Vec<u8>`) containing a valid UTF8 sequence. | `"Test"` | `0x1054657374` |
| `AccountId` | An [SS58 formatted](https://docs.substrate.io/reference/address-formats/) representation of an account. | `"5GDyPHLVHcQYPTWfygtPYeogQjyZy7J9fsi4brPhgEFq4pcv"` | `0xb80269ec...` |
| `Enum` | A fixed number of variants, each mutually exclusive. Encoded as the first byte identifying the index of the variant. | `{'Int': 8}` | `0x002a` |
| `Struct` | For structures, values are named but that is irrelevant for the encoding (only order matters). | `{"votes": [...], "id": 4}` | `0x04b80269...` |

## License

Apache 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
