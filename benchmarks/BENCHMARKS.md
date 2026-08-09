# Benchmarks
The following are benchmarks performed on this vs py-scale-codec on a few machines I have access to.

## Linux x86_64
Linux ubuntu-16gb-ash-1-archive 6.8.0-85-generic #85-Ubuntu SMP PREEMPT_DYNAMIC Thu Sep 18 15:26:59 UTC 2025 x86_64 x86_64 x86_64 GNU/Linux

Vendor ID:                AuthenticAMD

BIOS Vendor ID:         QEMU

Model name:             AMD EPYC-Milan Processor

BIOS Model name:      NotSpecified  CPU @ 2.0GHz

Python 3.12.3

| Benchmark                                       |  baseline |   current | speedup |
|-------------------------------------------------|----------:|----------:|--------:|
| u8 decode                                       |      3.64 |      2.81 |   1.29× |
| u16 decode                                      |      3.56 |      3.30 |   1.08× |
| u32 decode                                      |      3.61 |      3.33 |   1.08× |
| u64 decode                                      |      3.64 |      3.23 |   1.12× |
| u128 decode                                     |      3.64 |      3.12 |   1.17× |
| Compact<u32> decode                             |     19.27 |     17.42 |   1.11× |
| bool decode                                     |      3.45 |      3.04 |   1.14× |
| H256 decode                                     |      3.48 |      3.35 |   1.04× |
| AccountId decode (SS58 format 42)               |     15.01 |      5.11 |   2.94× |
| Str decode                                      |     22.29 |     19.73 |   1.13× |
| (u32, u64, bool) decode                         |   1408.67 |     14.02 | 100.49× |
| u32 encode                                      |      3.27 |      3.08 |   1.06× |
| u64 encode                                      |      3.28 |      2.93 |   1.12× |
| Compact<u32> encode                             |     16.87 |     14.97 |   1.13× |
| H256 encode                                     |      3.46 |      2.88 |   1.20× |
| Vec<u32> decode (64 elements)                   |    302.47 |     45.71 |   6.62× |
| Vec<u32> decode (1,024 elements)                |   4222.30 |    273.86 |  15.42× |
| Vec<u32> decode (16,384 elements)               |  66626.62 |   3782.02 |  17.62× |
| Bytes decode (1 KB)                             |     25.01 |     23.06 |   1.08× |
| Bytes decode (64 KB)                            |    101.28 |     99.66 |   1.02× |
| Bytes decode (512 KB)                           |    616.80 |    635.84 |   0.97× |
| Vec<EventRecord> decode (5 events, V10)         |    474.51 |    285.75 |   1.66× |
| MetadataVersioned decode (V10, 85 KB)           | 109650.28 |  87679.68 |   1.25× |
| MetadataVersioned decode (V13, 219 KB)          | 241260.48 | 197506.25 |   1.22× |
| MetadataVersioned decode (V14, 300 KB)          | 661970.11 | 454739.00 |   1.46× |
| Bittensor metadata + portable registry (254 KB) | 754292.08 | 517867.91 |   1.46× |
| batch_decode AccountId ×10                      |    152.99 |      7.53 |  20.31× |
| batch_decode AccountId ×100                     |   1519.42 |     67.98 |  22.35× |
| batch_decode AccountId ×1,000                   |  15248.00 |    665.73 |  22.90× |
| batch_decode mixed (AccountId/u32/u128) ×100    |    789.86 |     31.57 |  25.02× |


## macOS
Darwin Benjamins-MacBook-Pro.local 25.5.0 Darwin Kernel Version 25.5.0: Tue Jun  9 22:28:34 PDT 2026; root:xnu-12377.121.10~1/RELEASE_ARM64_T6041 arm64

Apple M4 Pro

Python 3.13.6

| Benchmark                                       |  baseline |   current | speedup |
|-------------------------------------------------|----------:|----------:|--------:|
| u8 decode                                       |      3.01 |      1.80 |   1.68× |
| u16 decode                                      |      2.99 |      1.86 |   1.61× |
| u32 decode                                      |      3.11 |      1.92 |   1.62× |
| u64 decode                                      |      3.09 |      1.89 |   1.64× |
| u128 decode                                     |      2.91 |      1.86 |   1.57× |
| Compact<u32> decode                             |      9.59 |      6.96 |   1.38× |
| bool decode                                     |      2.93 |      1.72 |   1.70× |
| H256 decode                                     |      2.93 |      1.77 |   1.65× |
| AccountId decode (SS58 format 42)               |     11.45 |      2.84 |   4.03× |
| Str decode                                      |     12.89 |      8.79 |   1.47× |
| (u32, u64, bool) decode                         |     21.96 |      8.46 |   2.60× |
| u32 encode                                      |      2.34 |      1.56 |   1.51× |
| u64 encode                                      |      2.33 |      1.57 |   1.48× |
| Compact<u32> encode                             |      8.85 |      6.47 |   1.37× |
| H256 encode                                     |      2.47 |      1.49 |   1.65× |
| Vec<u32> decode (64 elements)                   |    224.20 |     21.17 |  10.59× |
| Vec<u32> decode (1,024 elements)                |   3217.32 |    147.61 |  21.80× |
| Vec<u32> decode (16,384 elements)               |  50396.95 |   2150.48 |  23.44× |
| Bytes decode (1 KB)                             |     14.67 |     10.51 |   1.40× |
| Bytes decode (64 KB)                            |     64.15 |     63.42 |   1.01× |
| Bytes decode (512 KB)                           |    379.99 |    429.56 | 0.88× ◀ |
| Vec<EventRecord> decode (5 events, V10)         |    301.10 |    139.12 |   2.16× |
| MetadataVersioned decode (V10, 85 KB)           |  64958.83 |  37875.88 |   1.72× |
| MetadataVersioned decode (V13, 219 KB)          | 143029.99 |  84627.51 |   1.69× |
| MetadataVersioned decode (V14, 300 KB)          | 390902.34 | 195293.85 |   2.00× |
| Bittensor metadata + portable registry (254 KB) | 443089.47 | 219418.76 |   2.02× |
| batch_decode AccountId ×10                      |    116.66 |      3.97 |  29.41× |
| batch_decode AccountId ×100                     |   1159.47 |     36.05 |  32.17× |
| batch_decode AccountId ×1,000                   |  11530.59 |    357.76 |  32.23× |
| batch_decode mixed (AccountId/u32/u128) ×100    |    599.73 |     17.25 |  34.76× |
