"""Equivalence tests for the value-only decode fast path (`scalecodec._value_decode`).

Every case encodes a value with the classic path, then asserts that
`batch_decode` (which prefers the compiled value decoder) produces exactly the
same plain value as `create_scale_object(...).decode()` / `.value`.
"""

import unittest

from scalecodec.base import RuntimeConfigurationObject, ScaleBytes
from scalecodec.exceptions import RemainingScaleBytesNotEmptyException


class TestValueDecodeEquivalence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from scalecodec.type_registry import load_type_registry_preset

        cls.rc = RuntimeConfigurationObject(ss58_format=42)
        cls.rc.update_type_registry(load_type_registry_preset("core"))

    def classic_value(self, type_string, data: bytes):
        obj = self.rc.create_scale_object(type_string, data=ScaleBytes(bytes(data)))
        obj.decode()
        return obj.value

    def roundtrip(self, type_string, value):
        obj = self.rc.create_scale_object(type_string)
        data = bytes(obj.encode(value).data)

        classic = self.classic_value(type_string, data)
        batch = self.rc.batch_decode([type_string], [data])[0]

        self.assertEqual(type(classic), type(batch), f"{type_string}: type mismatch")
        self.assertEqual(classic, batch, f"{type_string}: value mismatch")
        return batch

    def test_value_decoder_engaged(self):
        # the types this suite covers must actually go through the fast path
        for ts in (
            "u32",
            "Vec<u32>",
            "Option<u64>",
            "(u8, u16)",
            "[u8; 4]",
            "Compact<u32>",
            "AccountId",
            "bool",
            "Vec<u8>",
        ):
            self.assertIsNotNone(self.rc.get_value_decoder(ts), ts)

    def test_unsupported_types_fall_back(self):
        # a bare 'Call' (GenericCall without a linked registry type) cannot
        # build its compile-time call table
        for ts in ("Call",):
            if self.rc.get_decoder_class(ts) is not None:
                self.assertIsNone(self.rc.get_value_decoder(ts), ts)

    def test_era(self):
        # immortal
        self.assertEqual(self.roundtrip("Era", "00"), "00")
        # mortal (period, phase)
        self.assertEqual(self.roundtrip("Era", (64, 35)), (64, 35))
        self.assertEqual(self.roundtrip("Era", (32768, 20000)), (32768, 20000))

    def test_unsigned_ints(self):
        for ts, values in {
            "u8": (0, 1, 255),
            "u16": (0, 65535, 300),
            "u32": (0, 2**32 - 1, 12345678),
            "u64": (0, 2**64 - 1, 2**63),
            "u128": (0, 2**128 - 1, 10**30),
            "u256": (0, 2**256 - 1, 10**70),
        }.items():
            for v in values:
                self.assertEqual(self.roundtrip(ts, v), v)

    def test_signed_ints(self):
        for ts, values in {
            "i8": (-128, 0, 127),
            "i16": (-32768, 32767),
            "i32": (-(2**31), 2**31 - 1),
            "i64": (-(2**63), 2**63 - 1),
            "i128": (-(2**127), 2**127 - 1),
            "i256": (-(2**255), 2**255 - 1),
        }.items():
            for v in values:
                self.assertEqual(self.roundtrip(ts, v), v)

    def test_bool(self):
        self.assertIs(self.roundtrip("bool", True), True)
        self.assertIs(self.roundtrip("bool", False), False)

    def test_compact(self):
        for v in (0, 63, 64, 16383, 16384, 2**30 - 1, 2**30, 2**32, 2**64, 2**100):
            self.assertEqual(self.roundtrip("Compact<u128>", v), v)

    def test_bytes_utf8_and_binary(self):
        # utf-8 decodable -> str
        self.assertEqual(self.roundtrip("Vec<u8>", "hello world"), "hello world")
        # non-utf8 -> 0x-hex
        self.assertEqual(self.roundtrip("Bytes", "0xff00fe"), "0xff00fe")
        self.assertEqual(self.roundtrip("Str", "unicode ✓ works"), "unicode ✓ works")

    def test_vec(self):
        self.assertEqual(
            self.roundtrip("Vec<u32>", [1, 2, 3, 2**32 - 1]), [1, 2, 3, 2**32 - 1]
        )
        self.assertEqual(self.roundtrip("Vec<u32>", []), [])
        self.assertEqual(
            self.roundtrip("Vec<Option<bool>>", [True, None, False]),
            [True, None, False],
        )
        self.assertEqual(self.roundtrip("Vec<Vec<u8>>", ["ab", "cd"]), ["ab", "cd"])

    def test_option(self):
        self.assertIsNone(self.roundtrip("Option<u32>", None))
        self.assertEqual(self.roundtrip("Option<u32>", 42), 42)
        self.assertIsNone(self.roundtrip("Option<Vec<u32>>", None))
        self.assertEqual(self.roundtrip("Option<Vec<u32>>", [7]), [7])

    def test_tuples(self):
        self.assertEqual(self.roundtrip("(u8, u16)", (5, 300)), (5, 300))
        self.assertEqual(self.roundtrip("(u8, u16, u32)", (1, 2, 3)), (1, 2, 3))
        # generic sub-types inside a tuple
        self.assertEqual(self.roundtrip("(u8, Option<u16>)", (9, 17)), (9, 17))

    def test_fixed_arrays(self):
        self.assertEqual(self.roundtrip("[u8; 4]", "0x01020304"), "0x01020304")
        self.assertEqual(self.roundtrip("[u16; 3]", [1, 2, 3]), [1, 2, 3])

    def test_h_types(self):
        h256 = "0x" + "ab" * 32
        self.assertEqual(self.roundtrip("H256", h256), h256)
        h160 = "0x" + "cd" * 20
        self.assertEqual(self.roundtrip("H160", h160), h160)

    def test_account_id_ss58(self):
        address = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"  # Alice, format 42
        self.assertEqual(self.roundtrip("AccountId", address), address)

    def test_btreemap(self):
        value = {1: 100, 2: 200}
        self.assertEqual(self.roundtrip("BTreeMap<u32, u64>", value), value)

    def test_null(self):
        self.assertIsNone(self.roundtrip("Null", None))

    def test_check_remaining_enforced(self):
        # trailing garbage must raise, matching decode(check_remaining=True)
        data = bytes(self.rc.create_scale_object("u8").encode(5).data) + b"\x00"
        with self.assertRaises(RemainingScaleBytesNotEmptyException):
            self.rc.batch_decode(["u8"], [data])

    def test_insufficient_bytes_raises(self):
        with self.assertRaises(RemainingScaleBytesNotEmptyException):
            self.rc.batch_decode(["u32"], [b"\x01\x02"])

    def test_cache_invalidation_on_registry_update(self):
        rc = RuntimeConfigurationObject(ss58_format=42)
        self.assertIsNotNone(rc.get_value_decoder("u32"))
        self.assertTrue(rc._value_decoder_cache)
        rc.update_type_registry_types({"MyAlias": "u32"})
        self.assertFalse(rc._value_decoder_cache)
        # still works after the update
        self.assertEqual(rc.batch_decode(["MyAlias"], [b"\x2a\x00\x00\x00"])[0], 42)


class TestValueDecodeScaleInfo(unittest.TestCase):
    """Equivalence across every type id of a real (fixture) runtime registry.

    For each scale_info type that the value decoder claims to support, decode
    the SCALE re-encoding of a synthesized value with both paths and compare.
    """

    @classmethod
    def setUpClass(cls):
        import json
        import os

        from scalecodec.base import RuntimeConfiguration
        from scalecodec.type_registry import load_type_registry_preset

        module_path = os.path.dirname(__file__)
        cls.metadata_fixture_dict = json.load(
            open(os.path.join(module_path, "fixtures", "metadata_hex.json"))
        )
        cls.runtime_config = RuntimeConfigurationObject(
            ss58_format=42, implements_scale_info=True
        )
        cls.runtime_config.update_type_registry(load_type_registry_preset("core"))
        cls.metadata_obj = cls.runtime_config.create_scale_object(
            "MetadataVersioned", data=ScaleBytes(cls.metadata_fixture_dict["V14"])
        )
        cls.metadata_obj.decode()
        cls.runtime_config.add_portable_registry(cls.metadata_obj)

    def test_registry_wide_equivalence(self):
        rc = self.runtime_config
        registry = self.metadata_obj.portable_registry.value_object[
            "types"
        ].value_object

        supported = 0
        compared = 0
        skipped_encode = 0

        for scale_info_type in registry:
            idx = scale_info_type["id"].value
            ts = f"scale_info::{idx}"

            value_fn = rc.get_value_decoder(ts)
            if value_fn is None:
                continue
            supported += 1

            # synthesize a value by decoding zero-bytes with the classic path
            # (gives a valid default-shaped value for most types), then
            # re-encode it to get authoritative SCALE bytes
            classic_cls = rc.get_decoder_class(ts)
            try:
                probe = classic_cls(data=ScaleBytes(bytes(512)))
                probe.decode(check_remaining=False)
                data = bytes(rc.create_scale_object(ts).encode(probe.value).data)
            except Exception:
                skipped_encode += 1
                continue

            classic_obj = rc.create_scale_object(ts, data=ScaleBytes(data))
            classic_value = classic_obj.decode()

            new_value = value_fn(data)

            self.assertEqual(
                type(classic_value), type(new_value), f"{ts}: type mismatch"
            )
            self.assertEqual(classic_value, new_value, f"{ts}: value mismatch")
            compared += 1

        # sanity: the fast path must cover a decent share of a real registry
        self.assertGreater(
            supported, 100, "value decoder supports suspiciously few types"
        )
        self.assertGreater(compared, 80, "too few types actually compared")


if __name__ == "__main__":
    unittest.main()
