# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True, nonecheck=False

import struct as _struct
from typing import Union

from scalecodec._scale_bytes cimport ScaleBytes
from scalecodec._scale_bytes import ScaleBytes as _ScaleBytes
from scalecodec.base import ScalePrimitive


class U8(ScalePrimitive):
    """
    Unsigned 8-bit int type, encoded in little-endian (LE) format
    """

    def process(self):
        cdef bytearray raw = self.get_next_bytes(1)
        return raw[0]

    def process_encode(self, value):
        cdef int v = int(value)
        if 0 <= v <= 255:
            return _ScaleBytes(bytearray(v.to_bytes(1, 'little')))
        else:
            raise ValueError('{} out of range for u8'.format(value))


class U16(ScalePrimitive):
    """
    Unsigned 16-bit int type, encoded in little-endian (LE) format
    """

    def process(self):
        cdef bytearray raw = self.get_next_bytes(2)
        cdef unsigned char[:] v = raw
        return <int>v[0] | (<int>v[1] << 8)

    def process_encode(self, value):
        cdef int v = int(value)
        if 0 <= v <= 65535:
            return _ScaleBytes(bytearray(v.to_bytes(2, 'little')))
        else:
            raise ValueError('{} out of range for u16'.format(value))


class U32(ScalePrimitive):
    """
    Unsigned 32-bit int type, encoded in little-endian (LE) format
    """

    def process(self):
        cdef bytearray raw = self.get_next_bytes(4)
        cdef unsigned char[:] v = raw
        return (<unsigned long>v[0] |
                (<unsigned long>v[1] << 8) |
                (<unsigned long>v[2] << 16) |
                (<unsigned long>v[3] << 24))

    def process_encode(self, value):
        cdef unsigned long v = int(value)
        if v <= 4294967295:
            return _ScaleBytes(bytearray(v.to_bytes(4, 'little')))
        else:
            raise ValueError('{} out of range for u32'.format(value))


class U64(ScalePrimitive):
    """
    Unsigned 64-bit int type, encoded in little-endian (LE) format
    """

    def process(self):
        cdef bytearray raw = self.get_next_bytes(8)
        cdef unsigned char[:] v = raw
        return (<unsigned long long>v[0] |
                (<unsigned long long>v[1] << 8) |
                (<unsigned long long>v[2] << 16) |
                (<unsigned long long>v[3] << 24) |
                (<unsigned long long>v[4] << 32) |
                (<unsigned long long>v[5] << 40) |
                (<unsigned long long>v[6] << 48) |
                (<unsigned long long>v[7] << 56))

    def process_encode(self, value):
        cdef unsigned long long v = int(value)
        if v <= 18446744073709551615:
            return _ScaleBytes(bytearray(v.to_bytes(8, 'little')))
        else:
            raise ValueError('{} out of range for u64'.format(value))


class U128(ScalePrimitive):
    """
    Unsigned 128-bit int type, encoded in little-endian (LE) format
    """

    def process(self):
        cdef bytearray raw = self.get_next_bytes(16)
        return int(int.from_bytes(raw, byteorder='little'))

    def process_encode(self, value):
        cdef object v = int(value)
        if 0 <= v <= 340282366920938463463374607431768211455:
            return _ScaleBytes(bytearray(v.to_bytes(16, 'little')))
        else:
            raise ValueError('{} out of range for u128'.format(value))


class U256(ScalePrimitive):
    """
    Unsigned 256-bit int type, encoded in little-endian (LE) format
    """

    def process(self):
        cdef bytearray raw = self.get_next_bytes(32)
        return int(int.from_bytes(raw, byteorder='little'))

    def process_encode(self, value):
        cdef object v = int(value)
        if 0 <= v <= (2**256 - 1):
            return _ScaleBytes(bytearray(v.to_bytes(32, 'little')))
        else:
            raise ValueError('{} out of range for u256'.format(value))


class I8(ScalePrimitive):
    """
    Signed 8-bit int type, encoded in little-endian (LE) format
    """

    def process(self):
        cdef bytearray raw = self.get_next_bytes(1)
        return int.from_bytes(raw, byteorder='little', signed=True)

    def process_encode(self, value):
        cdef int v = int(value)
        if -128 <= v <= 127:
            return _ScaleBytes(bytearray(v.to_bytes(1, 'little', signed=True)))
        else:
            raise ValueError('{} out of range for i8'.format(value))


class I16(ScalePrimitive):
    """
    Signed 16-bit int type, encoded in little-endian (LE) format
    """

    def process(self):
        cdef bytearray raw = self.get_next_bytes(2)
        return int.from_bytes(raw, byteorder='little', signed=True)

    def process_encode(self, value):
        cdef int v = int(value)
        if -32768 <= v <= 32767:
            return _ScaleBytes(bytearray(v.to_bytes(2, 'little', signed=True)))
        else:
            raise ValueError('{} out of range for i16'.format(value))


class I32(ScalePrimitive):
    """
    Signed 32-bit int type, encoded in little-endian (LE) format
    """

    def process(self):
        cdef bytearray raw = self.get_next_bytes(4)
        return int.from_bytes(raw, byteorder='little', signed=True)

    def process_encode(self, value):
        cdef int v = int(value)
        if -2147483648 <= v <= 2147483647:
            return _ScaleBytes(bytearray(v.to_bytes(4, 'little', signed=True)))
        else:
            raise ValueError('{} out of range for i32'.format(value))


class I64(ScalePrimitive):
    """
    Signed 64-bit int type, encoded in little-endian (LE) format
    """

    def process(self):
        cdef bytearray raw = self.get_next_bytes(8)
        return int.from_bytes(raw, byteorder='little', signed=True)

    def process_encode(self, value):
        cdef long long v = int(value)
        if -9223372036854775808 <= v <= 9223372036854775807:
            return _ScaleBytes(bytearray(v.to_bytes(8, 'little', signed=True)))
        else:
            raise ValueError('{} out of range for i64'.format(value))


class I128(ScalePrimitive):
    """
    Signed 128-bit int type, encoded in little-endian (LE) format
    """

    def process(self):
        cdef bytearray raw = self.get_next_bytes(16)
        return int.from_bytes(raw, byteorder='little', signed=True)

    def process_encode(self, value):
        cdef object v = int(value)
        if -(2**127) <= v <= 2**127 - 1:
            return _ScaleBytes(bytearray(v.to_bytes(16, 'little', signed=True)))
        else:
            raise ValueError('{} out of range for i128'.format(value))


class I256(ScalePrimitive):
    """
    Signed 256-bit int type, encoded in little-endian (LE) format
    """

    def process(self):
        cdef bytearray raw = self.get_next_bytes(32)
        return int.from_bytes(raw, byteorder='little', signed=True)

    def process_encode(self, value):
        cdef object v = int(value)
        if -(2**255) <= v <= 2**255 - 1:
            return _ScaleBytes(bytearray(v.to_bytes(32, 'little', signed=True)))
        else:
            raise ValueError('{} out of range for i256'.format(value))


class F32(ScalePrimitive):

    def process(self):
        cdef bytearray raw = self.get_next_bytes(4)
        return _struct.unpack('f', raw)[0]

    def process_encode(self, value):
        if type(value) is not float:
            raise ValueError('{} is not a float'.format(value))
        return _ScaleBytes(_struct.pack('f', value))


class F64(ScalePrimitive):

    def process(self):
        cdef bytearray raw = self.get_next_bytes(8)
        return _struct.unpack('d', raw)[0]

    def process_encode(self, value):
        if type(value) is not float:
            raise ValueError('{} is not a float'.format(value))
        return _ScaleBytes(_struct.pack('d', value))


class H160(ScalePrimitive):
    """
    Fixed-size uninterpreted hash type with 20 bytes (160 bits) size.
    """

    def process(self):
        cdef bytearray raw = self.get_next_bytes(20)
        return '0x{}'.format(raw.hex())

    def process_encode(self, value):
        if value[0:2] != '0x' or len(value) != 42:
            raise ValueError('Value should start with "0x" and should be 20 bytes long')
        return _ScaleBytes(value)


class H256(ScalePrimitive):
    """
    Fixed-size uninterpreted hash type with 32 bytes (256 bits) size.
    """

    def process(self):
        cdef bytearray raw = self.get_next_bytes(32)
        return '0x{}'.format(raw.hex())

    def process_encode(self, value):
        if value[0:2] != '0x' or len(value) != 66:
            raise ValueError('Value should start with "0x" and should be 32 bytes long')
        return _ScaleBytes(value)


class H512(ScalePrimitive):
    """
    Fixed-size uninterpreted hash type with 64 bytes (512 bits) size.
    """

    def process(self):
        cdef bytearray raw = self.get_next_bytes(64)
        return '0x{}'.format(raw.hex())

    def process_encode(self, value):
        if type(value) is bytes and len(value) != 64:
            raise ValueError('Value should be 64 bytes long')

        if type(value) is str and (value[0:2] != '0x' or len(value) != 130):
            raise ValueError('Value should start with "0x" and should be 64 bytes long')

        return _ScaleBytes(value)


class Bool(ScalePrimitive):
    """
    Boolean type
    """

    def process(self):
        return self.get_next_bool()

    def process_encode(self, value):
        if value is True:
            return _ScaleBytes('0x01')
        elif value is False:
            return _ScaleBytes('0x00')
        else:
            raise ValueError("Value must be boolean")
