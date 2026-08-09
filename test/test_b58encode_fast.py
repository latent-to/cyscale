"""Cross-validate the Cython base58 / SS58 fast paths in
``scalecodec.utils._ss58`` against the upstream ``base58`` package and the
original Python ``ss58_encode`` reference implementation.
"""

import os
import random
import unittest
from hashlib import blake2b

import base58

from scalecodec.utils._ss58 import (
    b58decode_bytes,
    b58encode_bytes,
    ss58_encode_fast,
)


def _ss58_encode_reference(address, ss58_format=42):
    """Verbatim copy of the original Python ``ss58_encode`` body, retained
    here as a reference implementation for cross-validation."""
    checksum_prefix = b"SS58PRE"

    if ss58_format < 0 or ss58_format > 16383 or ss58_format in [46, 47]:
        raise ValueError("Invalid value for ss58_format")

    if type(address) is bytes or type(address) is bytearray:
        address_bytes = address
    else:
        address_bytes = bytes.fromhex(address.replace("0x", ""))

    if len(address_bytes) in [32, 33]:
        checksum_length = 2
    elif len(address_bytes) in [1, 2, 4, 8]:
        checksum_length = 1
    else:
        raise ValueError("Invalid length for address")

    if ss58_format < 64:
        ss58_format_bytes = bytes([ss58_format])
    else:
        ss58_format_bytes = bytes(
            [
                ((ss58_format & 0b0000_0000_1111_1100) >> 2) | 0b0100_0000,
                (ss58_format >> 8) | ((ss58_format & 0b0000_0000_0000_0011) << 6),
            ]
        )

    input_bytes = ss58_format_bytes + address_bytes
    checksum = blake2b(checksum_prefix + input_bytes).digest()

    return base58.b58encode(input_bytes + checksum[:checksum_length]).decode()


class B58EncodeBytesTestCase(unittest.TestCase):
    def assert_matches_base58(self, data: bytes) -> None:
        self.assertEqual(b58encode_bytes(data), base58.b58encode(data))

    def test_empty(self):
        self.assertEqual(b58encode_bytes(b""), b"")

    def test_single_zero_byte(self):
        # Leading zero bytes map 1:1 to leading '1' chars.
        self.assert_matches_base58(b"\x00")

    def test_all_zero_bytes(self):
        self.assert_matches_base58(b"\x00" * 10)

    def test_leading_zeros_then_data(self):
        self.assert_matches_base58(b"\x00\x00\x00\xde\xad\xbe\xef")

    def test_single_nonzero_byte(self):
        for b in (1, 7, 57, 58, 59, 127, 255):
            self.assert_matches_base58(bytes([b]))

    def test_known_short_values(self):
        # Spot checks against the canonical alphabet ordering.
        self.assertEqual(b58encode_bytes(b"\x00\xff"), b"15Q")
        self.assertEqual(
            b58encode_bytes(b"Hello, World!"), b58encode_bytes(b"Hello, World!")
        )

    def test_various_lengths(self):
        rng = random.Random(0xCAFEBABE)
        for length in (1, 2, 7, 15, 16, 17, 31, 32, 33, 34, 35, 48, 64, 128, 200):
            data = bytes(rng.randint(0, 255) for _ in range(length))
            self.assert_matches_base58(data)

    def test_random_fuzz(self):
        rng = random.Random(0xDEADBEEF)
        for _ in range(200):
            length = rng.randint(0, 80)
            data = bytes(rng.randint(0, 255) for _ in range(length))
            self.assert_matches_base58(data)

    def test_accepts_bytearray(self):
        # Cython memoryview should accept any buffer-protocol object.
        self.assertEqual(
            b58encode_bytes(bytearray(b"\x01\x02\x03")),
            base58.b58encode(b"\x01\x02\x03"),
        )


class B58DecodeBytesTestCase(unittest.TestCase):
    def assert_matches_base58(self, encoded: bytes) -> None:
        self.assertEqual(b58decode_bytes(encoded), base58.b58decode(encoded))

    def test_empty(self):
        self.assertEqual(b58decode_bytes(b""), b"")
        self.assertEqual(b58decode_bytes(""), b"")

    def test_single_one_char(self):
        # "1" decodes to a single zero byte.
        self.assert_matches_base58(b"1")

    def test_all_ones(self):
        self.assert_matches_base58(b"11111")

    def test_roundtrip_with_b58encode_bytes(self):
        rng = random.Random(0x12345678)
        for length in (0, 1, 7, 16, 32, 33, 35, 64):
            data = bytes(rng.randint(0, 255) for _ in range(length))
            encoded = b58encode_bytes(data)
            self.assertEqual(b58decode_bytes(encoded), data)

    def test_accepts_str_and_bytes(self):
        encoded = base58.b58encode(b"\x01\x02\x03")
        self.assertEqual(b58decode_bytes(encoded), b"\x01\x02\x03")
        self.assertEqual(b58decode_bytes(encoded.decode("ascii")), b"\x01\x02\x03")
        self.assertEqual(b58decode_bytes(bytearray(encoded)), b"\x01\x02\x03")

    def test_strips_trailing_whitespace(self):
        encoded = base58.b58encode(b"\xde\xad\xbe\xef")
        self.assertEqual(b58decode_bytes(encoded + b"  \n"), b"\xde\xad\xbe\xef")
        self.assertEqual(
            b58decode_bytes(encoded.decode() + "  \n"), b"\xde\xad\xbe\xef"
        )

    def test_invalid_character_raises(self):
        with self.assertRaises(ValueError):
            b58decode_bytes("0OIl")  # all four are excluded from the alphabet

    def test_fuzz_matches_upstream(self):
        rng = random.Random(0x99999999)
        for _ in range(200):
            length = rng.randint(0, 80)
            data = bytes(rng.randint(0, 255) for _ in range(length))
            encoded = base58.b58encode(data)
            self.assert_matches_base58(encoded)


class SS58EncodeFastTestCase(unittest.TestCase):
    subkey_pairs = [
        {
            "address": "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY",
            "public_key": "0xd43593c715fdd31c61141abd04a99fd6822c8558854ccde39a5684e7a56da27d",
            "ss58_format": 42,
        },
        {
            "address": "5EU9mjvZdLRGyDFiBHjxrxvQuaaBpeTZCguhxM3yMX8cpZ2u",
            "public_key": "0x6a5a5957ce778c174c02c151e7c4917ac127b33ad8485f579f830fc15d31bc5a",
            "ss58_format": 42,
        },
        {
            # ecdsa (33-byte public key)
            "address": "4pbsSkWcBaYoFHrKJZp5fDVUKbqSYD9dhZZGvpp3vQ5ysVs5ybV",
            "public_key": "0x035676109c54b9a16d271abeb4954316a40a32bcce023ac14c8e26e958aa68fba9",
            "ss58_format": 200,
        },
        {
            "address": "yGF4JP7q5AK46d1FPCEm9sYQ4KooSjHMpyVAjLnsCSWVafPnf",
            "public_key": "0x66cd6cf085627d6c85af1aaf2bd10cf843033e929b4e3b1c2ba8e4aa46fe111b",
            "ss58_format": 255,
        },
        {
            # 2-byte ss58_format encoding
            "address": "mHm8k9Emsvyfp3piCauSH684iA6NakctF8dySQcX94GDdrJrE",
            "public_key": "0x44d5a3ac156335ea99d33a83c57c7146c40c8e2260a8a4adf4e7a86256454651",
            "ss58_format": 4242,
        },
        {
            "address": "r6Gr4gaMP8TsjhFbqvZhv3YvnasugLiRJpzpRHifsqqG18UXa",
            "public_key": "0x88f01441682a17b52d6ae12d1a5670cf675fd254897efabaa5069eb3a701ab73",
            "ss58_format": 14269,
        },
    ]

    def test_subkey_pairs_match_known_addresses(self):
        for pair in self.subkey_pairs:
            self.assertEqual(
                pair["address"],
                ss58_encode_fast(pair["public_key"], pair["ss58_format"]),
            )

    def test_matches_reference_for_subkey_pairs(self):
        for pair in self.subkey_pairs:
            self.assertEqual(
                _ss58_encode_reference(pair["public_key"], pair["ss58_format"]),
                ss58_encode_fast(pair["public_key"], pair["ss58_format"]),
            )

    def test_accepts_bytes_and_hex_str(self):
        pk_hex = self.subkey_pairs[0]["public_key"]
        pk_bytes = bytes.fromhex(pk_hex[2:])
        expected = self.subkey_pairs[0]["address"]
        self.assertEqual(ss58_encode_fast(pk_hex, 42), expected)
        self.assertEqual(ss58_encode_fast(pk_bytes, 42), expected)
        self.assertEqual(ss58_encode_fast(bytearray(pk_bytes), 42), expected)
        # Hex without 0x prefix.
        self.assertEqual(ss58_encode_fast(pk_hex[2:], 42), expected)

    def test_account_index_lengths(self):
        # 1, 2, 4, 8-byte account indices use a 1-byte checksum.
        for raw, ss58_format, expected in (
            ("0x01", 2, "g4b"),
            ("0x0001", 2, "3xygo"),
            ("0x01020304", 2, "zswfoZa"),
            ("0x2a2c0a0000000000", 2, "848Gh2GcGaZia"),
        ):
            self.assertEqual(ss58_encode_fast(raw, ss58_format), expected)

    def test_33_byte_address(self):
        self.assertEqual(
            "KWCv1L3QX9LDPwY4VzvLmarEmXjVJidUzZcinvVnmxAJJCBou",
            ss58_encode_fast(
                "0x03b9dc646dd71118e5f7fda681ad9eca36eb3ee96f344f582fbe7b5bcdebb13077"
            ),
        )

    def test_invalid_ss58_format_range(self):
        pk = self.subkey_pairs[0]["public_key"]
        for bad in (-1, 16384, 46, 47):
            with self.assertRaises(ValueError):
                ss58_encode_fast(pk, bad)

    def test_invalid_address_length(self):
        with self.assertRaises(ValueError):
            ss58_encode_fast(self.subkey_pairs[0]["public_key"][:30])

    def test_fuzz_matches_reference(self):
        rng = random.Random(0x5A5A5A5A)
        valid_addr_lengths = (1, 2, 4, 8, 32, 33)
        valid_formats = [f for f in range(0, 16384, 173) if f not in (46, 47)]
        for _ in range(150):
            length = rng.choice(valid_addr_lengths)
            data = bytes(rng.randint(0, 255) for _ in range(length))
            ss58_format = rng.choice(valid_formats)
            self.assertEqual(
                _ss58_encode_reference(data, ss58_format),
                ss58_encode_fast(data, ss58_format),
            )


if __name__ == "__main__":
    unittest.main()
