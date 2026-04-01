# Benchmarks
The following are benchmarks performed on this vs py-scale-codec on a few machines I have access to.

## Linux x86_64
Linux ubuntu-16gb-ash-1-archive 6.8.0-85-generic #85-Ubuntu SMP PREEMPT_DYNAMIC Thu Sep 18 15:26:59 UTC 2025 x86_64 x86_64 x86_64 GNU/Linux

Vendor ID:                AuthenticAMD

BIOS Vendor ID:         QEMU

Model name:             AMD EPYC-Milan Processor

BIOS Model name:      NotSpecified  CPU @ 2.0GHz

Python 3.12.3

| Benchmark                                    |  baseline |   current |  speedup |
|----------------------------------------------|-----------:|-----------:|----------:|
| u8 decode                                    |      3.66 |      2.70 |    1.36×   |
| u16 decode                                   |      3.67 |      3.05 |    1.20×   |
| u32 decode                                   |      3.69 |      2.96 |    1.25×   |
| u64 decode                                   |      3.75 |      2.95 |    1.27×   |
| u128 decode                                  |      3.71 |      2.93 |    1.27×   |
| Compact<u32> decode                          |     17.43 |     16.59 |    1.05×   |
| bool decode                                  |      3.63 |      2.86 |    1.27×   |
| H256 decode                                  |      3.67 |      2.99 |    1.23×   |
| AccountId decode (SS58 format 42)            |     14.78 |     14.38 |    1.03×   |
| Str decode                                   |     21.10 |     19.52 |    1.08×   |
| (u32, u64, bool) decode                      |   1345.66 |     13.37 |  100.62×   |
| u32 encode                                   |      3.40 |      2.74 |    1.24×   |
| u64 encode                                   |      3.41 |      2.73 |    1.25×   |
| Compact<u32> encode                          |     15.65 |     14.50 |    1.08×   |
| H256 encode                                  |      3.72 |      2.71 |    1.37×   |
| Vec<u32> decode (64 elements)                |    307.71 |    252.31 |    1.22×   |
| Vec<u32> decode (1,024 elements)             |   4270.40 |   3540.82 |    1.21×   |
| Vec<u32> decode (16,384 elements)            |  69396.95 |  55910.61 |    1.24×   |
| Bytes decode (1 KB)                          |     24.02 |     22.47 |    1.07×   |
| Bytes decode (64 KB)                         |     99.83 |    100.02 |    1.00×   |
| Bytes decode (512 KB)                        |    661.38 |    613.58 |    1.08×   |
| Vec<EventRecord> decode (5 events, V10)      |    494.98 |    405.55 |    1.22×   |
| MetadataVersioned decode (V10, 85 KB)        | 113743.46 | 100291.53 |    1.13×   |
| MetadataVersioned decode (V13, 219 KB)       | 241881.33 | 223401.34 |    1.08×   |
| MetadataVersioned decode (V14, 300 KB)       | 664058.82 | 605951.43 |    1.10×   |
| Bittensor metadata + portable registry (254 KB) | 766398.82 | 690645.06 |    1.11×   |
| batch_decode AccountId ×10                   |    154.35 |    101.78 |    1.52×   |
| batch_decode AccountId ×100                  |   1555.71 |   1023.24 |    1.52×   |
| batch_decode AccountId ×1,000                |  15344.88 |  10047.91 |    1.53×   |
| batch_decode mixed (AccountId/u32/u128) ×100 |    791.81 |    361.06 |    2.19×   |


## macOS
Darwin Benjamins-MacBook-Pro.local 25.3.0 Darwin Kernel Version 25.3.0: Wed Jan 28 20:51:28 PST 2026; root:xnu-12377.91.3~2/RELEASE_ARM64_T6041 arm64

Apple M4 Pro

Python 3.13.6

| Benchmark                                    |  baseline |   current |  speedup |
|----------------------------------------------|-----------:|-----------:|----------:|
| u8 decode                                    |      3.01 |      1.16 |    2.60×   |
| u16 decode                                   |      2.99 |      1.25 |    2.40×   |
| u32 decode                                   |      3.11 |      1.26 |    2.47×   |
| u64 decode                                   |      3.09 |      1.22 |    2.53×   |
| u128 decode                                  |      2.91 |      1.22 |    2.39×   |
| Compact<u32> decode                          |      9.59 |      4.38 |    2.19×   |
| bool decode                                  |      2.93 |      1.18 |    2.48×   |
| H256 decode                                  |      2.93 |      1.21 |    2.41×   |
| AccountId decode (SS58 format 42)            |     11.45 |      6.11 |    1.87×   |
| Str decode                                   |     12.89 |      5.82 |    2.22×   |
| (u32, u64, bool) decode                      |     21.96 |      5.59 |    3.93×   |
| u32 encode                                   |      2.34 |      1.10 |    2.13×   |
| u64 encode                                   |      2.33 |      1.20 |    1.93×   |
| Compact<u32> encode                          |      8.85 |      4.42 |    2.00×   |
| H256 encode                                  |      2.47 |      1.01 |    2.44×   |
| Vec<u32> decode (64 elements)                |    224.20 |     98.13 |    2.28×   |
| Vec<u32> decode (1,024 elements)             |   3217.32 |   1423.46 |    2.26×   |
| Vec<u32> decode (16,384 elements)            |  50396.95 |  22435.45 |    2.25×   |
| Bytes decode (1 KB)                          |     14.67 |      6.87 |    2.14×   |
| Bytes decode (64 KB)                         |     64.15 |     45.05 |    1.42×   |
| Bytes decode (512 KB)                        |    379.99 |    300.14 |    1.27×   |
| Vec<EventRecord> decode (5 events, V10)      |    301.10 |    135.32 |    2.23×   |
| MetadataVersioned decode (V10, 85 KB)        |  64958.83 |  29839.68 |    2.18×   |
| MetadataVersioned decode (V13, 219 KB)       | 143029.99 |  65651.69 |    2.18×   |
| MetadataVersioned decode (V14, 300 KB)       | 390902.34 | 183644.98 |    2.13×   |
| Bittensor metadata + portable registry (254 KB) | 443089.47 | 212345.78 |    2.09×   |
| batch_decode AccountId ×10                   |    116.66 |     42.07 |    2.77×   |
| batch_decode AccountId ×100                  |   1159.47 |    415.44 |    2.79×   |
| batch_decode AccountId ×1,000                |  11530.59 |   4112.27 |    2.80×   |
| batch_decode mixed (AccountId/u32/u128) ×100 |    599.73 |    147.75 |    4.06×   |