# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True, nonecheck=False

"""Fast Cython implementations of base58 / SS58 encoding for the AccountId
hot path.

`base58.b58encode_int` from the upstream `base58` package is O(N²) in the
output digit count due to repeated bytes-prepending. `b58encode_bytes` here
runs the standard base-256 → base-58 byte-array divmod algorithm directly on
a C buffer, then emits ASCII output in one pass — no Python big-int divmod,
no quadratic concatenation.

`ss58_encode_fast` inlines the prefix-byte construction, blake2b checksum,
and base58 encode that `scalecodec.utils.ss58.ss58_encode` performs, so the
whole SS58 encode of an AccountId costs one Python frame instead of ~6.
"""

from cpython.bytes cimport PyBytes_FromStringAndSize, PyBytes_AsString
from libc.stdint cimport uint32_t, uint64_t
from libc.stdlib cimport malloc, free
from libc.string cimport memcpy

from hashlib import blake2b

cdef extern from "Python.h":
    str PyUnicode_DecodeASCII(const char *s, Py_ssize_t size, const char *errors)


# Bitcoin base58 alphabet — the only alphabet SS58 uses. Kept as a module-level
# bytes object so the `_ALPHA` pointer stays valid for the module's lifetime.
cdef bytes _ALPHABET_BYTES = b'123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
cdef unsigned char* _ALPHA = <unsigned char*>PyBytes_AsString(_ALPHABET_BYTES)

# Inverse table: ASCII byte → base-58 digit (0..57), 0xFF for invalid chars.
cdef unsigned char _ALPHA_INV[256]

cdef _init_inverse_alphabet():
    cdef int i
    for i in range(256):
        _ALPHA_INV[i] = 0xFF
    for i in range(58):
        _ALPHA_INV[_ALPHA[i]] = <unsigned char>i

_init_inverse_alphabet()

cdef bytes _SS58PRE = b"SS58PRE"


# 58**5 — the largest power of 58 below 2**32. One long-division pass over
# u32 limbs by this constant peels off 5 base-58 digits at a time, so a
# 35-byte SS58 payload needs ~10 passes over ≤9 limbs instead of ~1300
# byte-at-a-time inner divmod steps.
DEF _B58_POW5 = 656356768


cdef Py_ssize_t _b58_digits(
    const unsigned char* data, Py_ssize_t n, unsigned char* digits_out
) noexcept nogil:
    """Base58 digit values (0..57) of ``data[0..n)``, least-significant first,
    written to ``digits_out``. ``data`` must have no leading zero bytes (the
    caller turns those into leading '1's). Returns the digit count.

    ``digits_out`` needs capacity for n*138//100 + 6 digits.
    """
    if n == 0:
        return 0

    # Pack big-endian bytes into big-endian u32 limbs; the first limb takes
    # the (possibly partial) leftover bytes so the rest fill exactly.
    cdef uint32_t limbs_stack[24]
    cdef uint32_t* limbs = limbs_stack
    cdef Py_ssize_t m = (n + 3) // 4
    cdef uint32_t acc = 0
    cdef Py_ssize_t i, k
    cdef Py_ssize_t head = n - (m - 1) * 4

    for i in range(head):
        acc = (acc << 8) | data[i]
    limbs[0] = acc
    for k in range(1, m):
        i = head + (k - 1) * 4
        limbs[k] = (
            (<uint32_t>data[i] << 24)
            | (<uint32_t>data[i + 1] << 16)
            | (<uint32_t>data[i + 2] << 8)
            | <uint32_t>data[i + 3]
        )

    cdef Py_ssize_t dc = 0
    cdef Py_ssize_t start = 0
    cdef uint64_t rem, cur

    while start < m:
        rem = 0
        for i in range(start, m):
            cur = (rem << 32) | <uint64_t>limbs[i]
            limbs[i] = <uint32_t>(cur // _B58_POW5)
            rem = cur % _B58_POW5
        for k in range(5):
            digits_out[dc] = <unsigned char>(rem % 58)
            rem //= 58
            dc += 1
        while start < m and limbs[start] == 0:
            start += 1

    # The final pass can emit high-order zero digits; drop them.
    while dc > 0 and digits_out[dc - 1] == 0:
        dc -= 1
    return dc


cpdef bytes b58encode_bytes(const unsigned char[:] data):
    """Base58-encode a byte buffer (Bitcoin alphabet).

    Equivalent to ``bytes(base58.b58encode(bytes(data)))`` but operates
    entirely on fixed-size byte buffers.
    """
    cdef Py_ssize_t n = data.shape[0]
    if n == 0:
        return b""

    # Each leading zero byte becomes a leading '1' in base58.
    cdef Py_ssize_t leading_zeros = 0
    while leading_zeros < n and data[leading_zeros] == 0:
        leading_zeros += 1

    cdef Py_ssize_t sig = n - leading_zeros
    # log2(256) / log2(58) ≈ 1.3661 — 138/100 is the standard safe bound,
    # plus slack for the up-to-4 extra zero digits of the final 5-digit pass.
    cdef Py_ssize_t cap = sig * 138 // 100 + 6
    cdef unsigned char digits_stack[136]
    cdef unsigned char* digits = digits_stack
    cdef uint32_t* limbs_heap = NULL
    cdef bint heap = sig > 92  # stack limbs cover 24 limbs = 92+ input bytes
    cdef Py_ssize_t digit_count, i

    if heap:
        digits = <unsigned char*>malloc(cap)
        if digits == NULL:
            raise MemoryError()
        try:
            digit_count = _b58_digits_large(&data[leading_zeros], sig, digits)
        except BaseException:
            free(digits)
            raise
    else:
        digit_count = _b58_digits(&data[leading_zeros], sig, digits)

    cdef bytes out = PyBytes_FromStringAndSize(NULL, leading_zeros + digit_count)
    cdef unsigned char* out_buf = <unsigned char*>PyBytes_AsString(out)

    for i in range(leading_zeros):
        out_buf[i] = _ALPHA[0]
    for i in range(digit_count):
        out_buf[leading_zeros + i] = _ALPHA[digits[digit_count - 1 - i]]

    if heap:
        free(digits)
    return out


cdef Py_ssize_t _b58_digits_large(
    const unsigned char* data, Py_ssize_t n, unsigned char* digits_out
):
    """Heap-allocating variant of ``_b58_digits`` for inputs too large for
    the fixed stack limb buffer. Same contract."""
    cdef Py_ssize_t m = (n + 3) // 4
    cdef uint32_t* limbs = <uint32_t*>malloc(m * sizeof(uint32_t))
    if limbs == NULL:
        raise MemoryError()

    cdef uint32_t acc = 0
    cdef Py_ssize_t i, k
    cdef Py_ssize_t head = n - (m - 1) * 4

    for i in range(head):
        acc = (acc << 8) | data[i]
    limbs[0] = acc
    for k in range(1, m):
        i = head + (k - 1) * 4
        limbs[k] = (
            (<uint32_t>data[i] << 24)
            | (<uint32_t>data[i + 1] << 16)
            | (<uint32_t>data[i + 2] << 8)
            | <uint32_t>data[i + 3]
        )

    cdef Py_ssize_t dc = 0
    cdef Py_ssize_t start = 0
    cdef uint64_t rem, cur

    while start < m:
        rem = 0
        for i in range(start, m):
            cur = (rem << 32) | <uint64_t>limbs[i]
            limbs[i] = <uint32_t>(cur // _B58_POW5)
            rem = cur % _B58_POW5
        for k in range(5):
            digits_out[dc] = <unsigned char>(rem % 58)
            rem //= 58
            dc += 1
        while start < m and limbs[start] == 0:
            start += 1

    free(limbs)
    while dc > 0 and digits_out[dc - 1] == 0:
        dc -= 1
    return dc


cpdef bytes b58decode_bytes(object data):
    """Base58-decode an ASCII input (str or bytes-like) to raw bytes.

    Equivalent to ``base58.b58decode(data)`` for the Bitcoin alphabet. Raises
    ``ValueError`` on characters outside the alphabet.
    """
    cdef bytes ascii_bytes
    if isinstance(data, str):
        ascii_bytes = data.rstrip().encode("ascii")
    elif isinstance(data, (bytes, bytearray, memoryview)):
        ascii_bytes = bytes(data).rstrip()
    else:
        raise TypeError("b58decode_bytes: expected str or bytes-like")

    cdef Py_ssize_t n = len(ascii_bytes)
    if n == 0:
        return b""

    cdef const unsigned char* in_buf = <const unsigned char*>PyBytes_AsString(ascii_bytes)

    # Leading '1' chars map to leading zero bytes in the output.
    cdef Py_ssize_t leading_ones = 0
    while leading_ones < n and in_buf[leading_ones] == _ALPHA[0]:
        leading_ones += 1

    # log2(58) / log2(256) ≈ 0.7322; 733/1000 is the standard safe bound.
    cdef Py_ssize_t cap = (n - leading_ones) * 733 // 1000 + 1
    cdef bytearray buf_ba = bytearray(cap)
    cdef unsigned char[:] buf = buf_ba
    cdef Py_ssize_t length = 0

    cdef Py_ssize_t i, j
    cdef uint32_t carry
    cdef unsigned char digit

    for i in range(leading_ones, n):
        digit = _ALPHA_INV[in_buf[i]]
        if digit == 0xFF:
            raise ValueError(f"Invalid character {chr(in_buf[i])!r}")
        carry = digit
        j = 0
        while j < length or carry > 0:
            if j < length:
                carry += <uint32_t>buf[j] * <uint32_t>58
            buf[j] = <unsigned char>(carry & 0xFF)
            carry >>= 8
            j += 1
        length = j

    cdef Py_ssize_t out_len = leading_ones + length
    cdef bytes out = PyBytes_FromStringAndSize(NULL, out_len)
    cdef unsigned char* out_buf = <unsigned char*>PyBytes_AsString(out)

    for i in range(leading_ones):
        out_buf[i] = 0
    for i in range(length):
        out_buf[leading_ones + i] = buf[length - 1 - i]

    return out


cpdef str ss58_encode_fast(object address, int ss58_format=42):
    """Encode an account ID (or account index bytes) as an SS58 address.

    Mirrors ``scalecodec.utils.ss58.ss58_encode`` in behavior; differs only
    in that the prefix-byte construction, blake2b checksum, and base58
    encoding happen in this single Cython entry point.
    """
    if ss58_format < 0 or ss58_format > 16383 or ss58_format == 46 or ss58_format == 47:
        raise ValueError("Invalid value for ss58_format")

    cdef bytes address_bytes
    if isinstance(address, bytes):
        address_bytes = address
    elif isinstance(address, bytearray):
        address_bytes = bytes(address)
    elif isinstance(address, str):
        if address.startswith("0x"):
            address_bytes = bytes.fromhex(address[2:])
        else:
            address_bytes = bytes.fromhex(address)
    else:
        raise TypeError("address must be bytes, bytearray, or hex str")

    cdef Py_ssize_t addr_len = len(address_bytes)
    cdef int checksum_length
    if addr_len == 32 or addr_len == 33:
        checksum_length = 2
    elif addr_len == 1 or addr_len == 2 or addr_len == 4 or addr_len == 8:
        checksum_length = 1
    else:
        raise ValueError("Invalid length for address")

    # Assemble SS58PRE + prefix + address in one buffer; the checksum input
    # is the whole thing, the base58 payload starts after SS58PRE.
    cdef Py_ssize_t prefix_len = 1 if ss58_format < 64 else 2
    cdef bytes checksum_input = PyBytes_FromStringAndSize(
        NULL, 7 + prefix_len + addr_len
    )
    cdef unsigned char* ci = <unsigned char*>PyBytes_AsString(checksum_input)
    memcpy(ci, <const char*>PyBytes_AsString(_SS58PRE), 7)
    if ss58_format < 64:
        ci[7] = <unsigned char>ss58_format
    else:
        ci[7] = <unsigned char>(((ss58_format & 0x00FC) >> 2) | 0x40)
        ci[8] = <unsigned char>((ss58_format >> 8) | ((ss58_format & 0x0003) << 6))
    memcpy(ci + 7 + prefix_len, PyBytes_AsString(address_bytes), addr_len)

    cdef bytes checksum = blake2b(checksum_input).digest()

    # payload = prefix + address + checksum[:checksum_length] — max 37 bytes.
    cdef unsigned char payload[40]
    cdef Py_ssize_t payload_len = prefix_len + addr_len + checksum_length
    memcpy(payload, ci + 7, prefix_len + addr_len)
    memcpy(
        payload + prefix_len + addr_len,
        PyBytes_AsString(checksum),
        checksum_length,
    )

    cdef Py_ssize_t leading_zeros = 0
    while leading_zeros < payload_len and payload[leading_zeros] == 0:
        leading_zeros += 1

    cdef unsigned char digits[64]
    cdef Py_ssize_t digit_count = _b58_digits(
        payload + leading_zeros, payload_len - leading_zeros, digits
    )

    cdef char out[64]
    cdef Py_ssize_t i
    for i in range(leading_zeros):
        out[i] = _ALPHA[0]
    for i in range(digit_count):
        out[leading_zeros + i] = _ALPHA[digits[digit_count - 1 - i]]

    return PyUnicode_DecodeASCII(out, leading_zeros + digit_count, NULL)