# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True, nonecheck=False

"""Value-only SCALE decoding: plain Python values with no ScaleType objects.

The classic decode path builds one ScaleType instance per node of the type
tree (a `System.Account` value allocates ~a dozen objects), purely so the
result can carry `value_object` alongside `value_serialized`. The batch read
paths only ever consume `.value`, so all of that allocation is overhead.

This module compiles a type into a small tree of `_Node` descriptors once
(per runtime configuration), then decodes each SCALE blob by walking that
tree with a single recursive C function that reads straight out of the input
buffer and builds plain values (int/str/dict/list/tuple/None) directly.

Only types whose semantics are fully known are compiled: the compiler
resolves the type through the existing dynamic decoder classes and checks —
by `process` method identity — that each class decodes with a known base
implementation (Struct, Enum, Vec, primitives, ...). Any class that overrides
`process` (GenericCall, Era, Data, metadata types, ...) raises
:class:`UnsupportedType` and the caller falls back to the classic path, so
behavior can never silently diverge for exotic types.

Decoded values are shape-identical to `.value` (``value_serialized``) of the
classic path, and a full decode enforces exact buffer consumption the same
way ``decode(check_remaining=True)`` does.
"""

from cpython.bytes cimport PyBytes_FromStringAndSize
from libc.stdint cimport int8_t, int16_t, int32_t, int64_t, uint64_t
from libc.string cimport memcpy

from hashlib import blake2b

from scalecodec.exceptions import (
    InvalidScaleTypeValueException,
    RemainingScaleBytesNotEmptyException,
)
from scalecodec.utils._ss58 import ss58_encode_fast


class UnsupportedType(TypeError):
    """Raised at compile time for types the value decoder cannot handle."""


# --- ops ------------------------------------------------------------------------

DEF OP_U8 = 0
DEF OP_U16 = 1
DEF OP_U32 = 2
DEF OP_U64 = 3
DEF OP_U128 = 4
DEF OP_U256 = 5
DEF OP_I8 = 6
DEF OP_I16 = 7
DEF OP_I32 = 8
DEF OP_I64 = 9
DEF OP_I128 = 10
DEF OP_I256 = 11
DEF OP_BOOL = 12
DEF OP_COMPACT = 13
DEF OP_BYTES = 14          # Vec<u8> / Bytes / Str: utf-8 if possible, else 0x-hex
DEF OP_VEC = 15
DEF OP_ARRAY_U8 = 16       # [u8; N] -> 0x-hex ('[]' when N == 0)
DEF OP_ARRAY = 17
DEF OP_STRUCT = 18
DEF OP_TUPLE = 19
DEF OP_TUPLE1 = 20
DEF OP_ENUM = 21
DEF OP_ENUM_VALUES = 22    # value_list enum
DEF OP_OPTION = 23
DEF OP_ACCOUNT_ID = 24
DEF OP_H160 = 25
DEF OP_H256 = 26
DEF OP_H512 = 27
DEF OP_BITVEC = 28
DEF OP_NULL = 29
DEF OP_BTREEMAP = 30       # child decodes to list of (k, v); result is dict
DEF OP_WRAP = 31           # value of single child (Map/BTreeSet wrappers)
DEF OP_F32 = 32
DEF OP_F64 = 33
DEF OP_HEXBYTES = 34       # compact length + raw bytes -> 0x-hex
DEF OP_OPTION_BYTES = 35   # Option<Vec<u8>> with OptionBytes semantics
DEF OP_SET = 36            # bitmask int -> list of set names
DEF OP_MULTIADDR = 37      # MultiAddress with GenericMultiAddress result shapes
DEF OP_CALL = 38           # runtime Call with GenericCall's serialized dict shape
DEF OP_ERA = 39            # '00' (immortal) or (period, phase)
DEF OP_EVENT = 40          # runtime event with GenericScaleInfoEvent's dict shape
DEF OP_EVENT_RECORD = 41   # EventRecord with GenericEventRecord's dict shape


cdef class _Node:
    cdef int op
    cdef Py_ssize_t n           # element count / fixed byte length
    cdef list children          # sub-nodes (or [child])
    cdef list keys              # struct field names / enum variant names
    cdef object aux             # runtime_config (ACCOUNT_ID), value list, set masks

    def __cinit__(self):
        self.op = OP_NULL
        self.n = 0
        self.children = None
        self.keys = None
        self.aux = None


# --- decode interpreter -----------------------------------------------------------

cdef inline void _need(Py_ssize_t p, Py_ssize_t want, Py_ssize_t buflen) except *:
    if p + want > buflen:
        raise RemainingScaleBytesNotEmptyException(
            f'No more bytes available (needs {want} at offset {p}, length {buflen})'
        )


cdef inline uint64_t _read_uint(const unsigned char* buf, Py_ssize_t p, int nbytes) noexcept:
    cdef uint64_t v = 0
    cdef int i
    for i in range(nbytes):
        v |= (<uint64_t>buf[p + i]) << (8 * i)
    return v


cdef object _read_compact(const unsigned char* buf, Py_ssize_t buflen, Py_ssize_t* pos):
    cdef Py_ssize_t p = pos[0]
    _need(p, 1, buflen)
    cdef int b0 = buf[p]
    cdef int mode = b0 & 3
    cdef Py_ssize_t length
    if mode == 0:
        pos[0] = p + 1
        return b0 >> 2
    elif mode == 1:
        _need(p, 2, buflen)
        pos[0] = p + 2
        return <object>((<uint64_t>_read_uint(buf, p, 2)) >> 2)
    elif mode == 2:
        _need(p, 4, buflen)
        pos[0] = p + 4
        return <object>((<uint64_t>_read_uint(buf, p, 4)) >> 2)
    else:
        # big-integer mode: the prefix byte encodes how many bytes follow
        length = 4 + (b0 >> 2)
        _need(p + 1, length, buflen)
        pos[0] = p + 1 + length
        return int.from_bytes(
            PyBytes_FromStringAndSize(<const char*>(buf + p + 1), length), 'little'
        )


cdef object _dec(_Node nd, const unsigned char* buf, Py_ssize_t buflen, Py_ssize_t* pos):
    cdef int op = nd.op
    cdef Py_ssize_t p = pos[0]
    cdef Py_ssize_t i, count, total
    cdef int idx
    cdef object v
    cdef list out
    cdef dict d
    cdef _Node child
    cdef bytes raw
    cdef float f32val
    cdef double f64val

    if op == OP_U8:
        _need(p, 1, buflen)
        pos[0] = p + 1
        return <object>buf[p]
    elif op == OP_U16:
        _need(p, 2, buflen)
        pos[0] = p + 2
        return <object>_read_uint(buf, p, 2)
    elif op == OP_U32:
        _need(p, 4, buflen)
        pos[0] = p + 4
        return <object>_read_uint(buf, p, 4)
    elif op == OP_U64:
        _need(p, 8, buflen)
        pos[0] = p + 8
        return <object>_read_uint(buf, p, 8)
    elif op == OP_U128 or op == OP_U256:
        total = 16 if op == OP_U128 else 32
        _need(p, total, buflen)
        pos[0] = p + total
        return int.from_bytes(PyBytes_FromStringAndSize(<const char*>(buf + p), total), 'little')
    elif op == OP_I8:
        _need(p, 1, buflen)
        pos[0] = p + 1
        return <object>(<int8_t>buf[p])
    elif op == OP_I16:
        _need(p, 2, buflen)
        pos[0] = p + 2
        return <object>(<int16_t>_read_uint(buf, p, 2))
    elif op == OP_I32:
        _need(p, 4, buflen)
        pos[0] = p + 4
        return <object>(<int32_t>_read_uint(buf, p, 4))
    elif op == OP_I64:
        _need(p, 8, buflen)
        pos[0] = p + 8
        return <object>(<int64_t>_read_uint(buf, p, 8))
    elif op == OP_I128 or op == OP_I256:
        total = 16 if op == OP_I128 else 32
        _need(p, total, buflen)
        pos[0] = p + total
        return int.from_bytes(
            PyBytes_FromStringAndSize(<const char*>(buf + p), total), 'little', signed=True
        )
    elif op == OP_BOOL:
        _need(p, 1, buflen)
        pos[0] = p + 1
        if buf[p] == 0:
            return False
        elif buf[p] == 1:
            return True
        raise InvalidScaleTypeValueException('Invalid value for datatype "bool"')
    elif op == OP_COMPACT:
        return _read_compact(buf, buflen, pos)
    elif op == OP_BYTES:
        count = <Py_ssize_t>_read_compact(buf, buflen, pos)
        p = pos[0]
        _need(p, count, buflen)
        pos[0] = p + count
        raw = PyBytes_FromStringAndSize(<const char*>(buf + p), count)
        try:
            return raw.decode()
        except UnicodeDecodeError:
            return '0x' + raw.hex()
    elif op == OP_VEC:
        count = <Py_ssize_t>_read_compact(buf, buflen, pos)
        child = <_Node>nd.children[0]
        out = []
        for i in range(count):
            out.append(_dec(child, buf, buflen, pos))
        return out
    elif op == OP_ARRAY_U8:
        count = nd.n
        if count == 0:
            return []
        _need(p, count, buflen)
        pos[0] = p + count
        return '0x' + PyBytes_FromStringAndSize(<const char*>(buf + p), count).hex()
    elif op == OP_ARRAY:
        child = <_Node>nd.children[0]
        out = []
        for i in range(nd.n):
            out.append(_dec(child, buf, buflen, pos))
        return out
    elif op == OP_STRUCT:
        d = {}
        for i in range(len(nd.children)):
            d[nd.keys[i]] = _dec(<_Node>nd.children[i], buf, buflen, pos)
        return d
    elif op == OP_TUPLE:
        out = []
        for i in range(len(nd.children)):
            out.append(_dec(<_Node>nd.children[i], buf, buflen, pos))
        return tuple(out)
    elif op == OP_TUPLE1 or op == OP_WRAP:
        return _dec(<_Node>nd.children[0], buf, buflen, pos)
    elif op == OP_ENUM:
        _need(p, 1, buflen)
        idx = buf[p]
        pos[0] = p + 1
        if idx >= len(nd.children):
            raise ValueError("Index '{}' not present in Enum type mapping".format(idx))
        v = nd.keys[idx]
        child = <_Node>nd.children[idx]
        if child is None:
            # unit variant — including (None, 'Null') gap placeholders, which the
            # classic path also decodes to the bare variant name (None)
            return v
        return {v: _dec(child, buf, buflen, pos)}
    elif op == OP_ENUM_VALUES:
        _need(p, 1, buflen)
        idx = buf[p]
        pos[0] = p + 1
        if idx >= len(<list>nd.aux):
            raise ValueError("Index '{}' not present in Enum value list".format(idx))
        return (<list>nd.aux)[idx]
    elif op == OP_OPTION:
        _need(p, 1, buflen)
        pos[0] = p + 1
        if nd.children is not None and buf[p] != 0:
            return _dec(<_Node>nd.children[0], buf, buflen, pos)
        return None
    elif op == OP_OPTION_BYTES:
        _need(p, 1, buflen)
        pos[0] = p + 1
        if buf[p] != 0:
            count = <Py_ssize_t>_read_compact(buf, buflen, pos)
            p = pos[0]
            _need(p, count, buflen)
            pos[0] = p + count
            raw = PyBytes_FromStringAndSize(<const char*>(buf + p), count)
            try:
                return raw.decode()
            except UnicodeDecodeError:
                return '0x' + raw.hex()
        return None
    elif op == OP_ACCOUNT_ID:
        _need(p, 32, buflen)
        pos[0] = p + 32
        raw = PyBytes_FromStringAndSize(<const char*>(buf + p), 32)
        v = nd.aux.ss58_format
        if v is not None:
            try:
                return ss58_encode_fast(raw, v)
            except ValueError:
                pass
        return '0x' + raw.hex()
    elif op == OP_H160 or op == OP_H256 or op == OP_H512:
        total = 20 if op == OP_H160 else (32 if op == OP_H256 else 64)
        _need(p, total, buflen)
        pos[0] = p + total
        return '0x' + PyBytes_FromStringAndSize(<const char*>(buf + p), total).hex()
    elif op == OP_BITVEC:
        count = <Py_ssize_t>_read_compact(buf, buflen, pos)  # number of bits
        total = (count + 7) // 8
        p = pos[0]
        _need(p, total, buflen)
        pos[0] = p + total
        v = int.from_bytes(PyBytes_FromStringAndSize(<const char*>(buf + p), total), 'little')
        return '0b' + bin(v)[2:].zfill(count)
    elif op == OP_NULL:
        return None
    elif op == OP_BTREEMAP:
        v = _dec(<_Node>nd.children[0], buf, buflen, pos)
        return {
            (tuple(key) if isinstance(key, list) else key): value
            for key, value in v
        }
    elif op == OP_F32:
        _need(p, 4, buflen)
        pos[0] = p + 4
        memcpy(&f32val, buf + p, 4)
        return f32val
    elif op == OP_F64:
        _need(p, 8, buflen)
        pos[0] = p + 8
        memcpy(&f64val, buf + p, 8)
        return f64val
    elif op == OP_HEXBYTES:
        count = <Py_ssize_t>_read_compact(buf, buflen, pos)
        p = pos[0]
        _need(p, count, buflen)
        pos[0] = p + count
        return '0x' + PyBytes_FromStringAndSize(<const char*>(buf + p), count).hex()
    elif op == OP_SET:
        v = _dec(<_Node>nd.children[0], buf, buflen, pos)
        out = []
        if v > 0:
            for name, mask in <list>nd.aux:
                if v & mask > 0:
                    out.append(name)
        return out
    elif op == OP_MULTIADDR:
        _need(p, 1, buflen)
        idx = buf[p]
        pos[0] = p + 1
        if idx >= len(nd.children) or nd.keys[idx] is None:
            raise ValueError("Index '{}' not present in Enum type mapping".format(idx))
        child = <_Node>nd.children[idx]
        v = _dec(child, buf, buflen, pos) if child is not None else None
        if idx == 0 or idx == 1:
            # Id -> the ss58 address itself; Index -> the bare account index
            return v
        return {nd.keys[idx]: v}
    elif op == OP_CALL:
        # aux: {pallet_index: (pallet_name, {call_index: (call_name,
        #        [(arg_name, converted_type_string, _Node), ...])})}
        _need(p, 2, buflen)
        v = (<dict>nd.aux).get(buf[p])
        if v is None:
            raise ValueError(f'Pallet with index {buf[p]} not found in Call table')
        idx = buf[p + 1]
        entry = (<dict>(<tuple>v)[1]).get(idx)
        if entry is None:
            raise ValueError(f"Index '{idx}' not present in Enum type mapping")
        pos[0] = p + 2
        out = []
        for arg_name, arg_type, child in <list>(<tuple>entry)[1]:
            out.append({
                'name': arg_name,
                'type': arg_type,
                'value': _dec(<_Node>child, buf, buflen, pos),
            })
        raw = PyBytes_FromStringAndSize(<const char*>(buf + p), pos[0] - p)
        return {
            'call_index': '0x{:02x}{:02x}'.format(buf[p], idx),
            'call_function': (<tuple>entry)[0],
            'call_module': (<tuple>v)[0],
            'call_args': out,
            'call_hash': '0x' + blake2b(raw, digest_size=32).digest().hex(),
        }
    elif op == OP_EVENT:
        return _dec_event(<dict>nd.aux, buf, buflen, pos)
    elif op == OP_EVENT_RECORD:
        # phase: a plain enum value — a variant name, or {name: payload}
        v = _dec(<_Node>nd.children[0], buf, buflen, pos)
        if isinstance(v, dict):
            phase_name = next(iter(v))
            extrinsic_idx = v[phase_name] if phase_name == 'ApplyExtrinsic' else None
        else:
            phase_name = v
            extrinsic_idx = None
        p = pos[0]
        _need(p, 1, buflen)
        idx = buf[p]                      # outer event enum index
        d = _dec_event(<dict>nd.aux, buf, buflen, pos)
        v = _dec(<_Node>nd.children[1], buf, buflen, pos)   # topics
        return {
            'phase': phase_name,
            'extrinsic_idx': extrinsic_idx,
            'event': d,
            'event_index': idx,
            'module_id': d['module_id'],
            'event_id': d['event_id'],
            'attributes': d['attributes'],
            'topics': v,
        }
    elif op == OP_ERA:
        _need(p, 1, buflen)
        if buf[p] == 0:
            pos[0] = p + 1
            return '00'
        _need(p, 2, buflen)
        pos[0] = p + 2
        i = buf[p] + (buf[p + 1] << 8)   # encoded era, little-endian
        count = 2 << (i % (1 << 4))      # period
        total = (count >> 12) if (count >> 12) > 1 else 1  # quantize factor
        i = (i >> 4) * total             # phase
        if count >= 4 and i < count:
            return (<object>count, <object>i)
        raise ValueError('Invalid phase and period: {}, {}'.format(i, count))

    raise UnsupportedType(f'Unknown value-decode op {op}')


cdef dict _dec_event(dict table, const unsigned char* buf, Py_ssize_t buflen, Py_ssize_t* pos):
    """Decode a runtime event enum into GenericScaleInfoEvent's dict shape."""
    cdef Py_ssize_t p = pos[0]
    _need(p, 2, buflen)
    v = table.get(buf[p])
    if v is None:
        raise ValueError("Index '{}' not present in Enum type mapping".format(buf[p]))
    cdef int idx = buf[p + 1]
    entry = (<dict>(<tuple>v)[1]).get(idx)
    if entry is None:
        raise ValueError("Index '{}' not present in Enum type mapping".format(idx))
    pos[0] = p + 2
    payload_node = (<tuple>entry)[1]
    if payload_node is not None:
        attributes = _dec(<_Node>payload_node, buf, buflen, pos)
    else:
        attributes = None
    return {
        'event_index': '{:02x}{:02x}'.format(buf[p], idx),
        'module_id': (<tuple>v)[0],
        'event_id': (<tuple>entry)[0],
        'attributes': attributes,
    }


cdef class ValueDecoder:
    """A compiled decoder for one type: call with SCALE bytes, get a plain value."""
    cdef _Node _node

    def __call__(self, data):
        cdef const unsigned char[:] mv = data
        cdef Py_ssize_t buflen = mv.shape[0]
        cdef const unsigned char* buf
        cdef Py_ssize_t pos = 0
        if buflen == 0:
            buf = NULL
        else:
            buf = &mv[0]
        result = _dec(self._node, buf, buflen, &pos)
        if pos != buflen:
            raise RemainingScaleBytesNotEmptyException(
                f'Decoding value-decoder - Current offset: {pos} / length: {buflen}'
            )
        return result

    def decode_at(self, data, Py_ssize_t offset):
        """Decode one value starting at `offset` inside `data`.

        Returns ``(value, new_offset)`` and — unlike ``__call__`` — does not
        require the buffer to be fully consumed, so it can be used to decode a
        component in the middle of a larger stream (e.g. the Call enum inside
        an extrinsic).
        """
        cdef const unsigned char[:] mv = data
        cdef Py_ssize_t buflen = mv.shape[0]
        cdef const unsigned char* buf
        cdef Py_ssize_t pos = offset
        if buflen == 0:
            buf = NULL
        else:
            buf = &mv[0]
        result = _dec(self._node, buf, buflen, &pos)
        return result, pos


# --- compiler ------------------------------------------------------------------------


def build_decoder(runtime_config, type_string):
    """Compile `type_string` into a :class:`ValueDecoder` for `runtime_config`.

    Raises :class:`UnsupportedType` for any type whose decode semantics are not
    fully covered; callers fall back to the classic object-based path.
    """
    cdef ValueDecoder dec = ValueDecoder.__new__(ValueDecoder)
    node_cache = runtime_config.__dict__.setdefault('_value_node_cache', {})
    dec._node = _build_node(runtime_config, type_string, node_cache)
    return dec


cdef dict _PRIM_OPS = {}
cdef dict _KNOWN = {}


cdef _init_dispatch_tables():
    """Late import of the type modules (they import base, which imports us)."""
    from scalecodec import _primitives as P
    from scalecodec._compact import Compact
    from scalecodec import types as T

    _PRIM_OPS.update({
        P.U8.process: OP_U8, P.U16.process: OP_U16, P.U32.process: OP_U32,
        P.U64.process: OP_U64, P.U128.process: OP_U128, P.U256.process: OP_U256,
        P.I8.process: OP_I8, P.I16.process: OP_I16, P.I32.process: OP_I32,
        P.I64.process: OP_I64, P.I128.process: OP_I128, P.I256.process: OP_I256,
        P.Bool.process: OP_BOOL, P.F32.process: OP_F32, P.F64.process: OP_F64,
        P.H160.process: OP_H160, P.H512.process: OP_H512,
        Compact.process: OP_COMPACT,
    })
    _KNOWN.update({
        'account_id': T.GenericAccountId.process,
        'h256': P.H256.process,
        'bytes': T.Bytes.process,
        'hexbytes': T.HexBytes.process,
        'option_bytes': T.OptionBytes.process,
        'option': T.Option.process,
        'vec': T.Vec.process,
        'array': T.FixedLengthArray.process,
        'struct': T.Struct.process,
        'tuple': T.Tuple.process,
        'enum': T.Enum.process,
        'null': T.Null.process,
        'bitvec': T.BitVec.process,
        'btreemap': T.BTreeMap.process,
        'map': T.Map.process,
        'btreeset': T.BTreeSet.process,
        'set': T.Set.process,
        'multiaddress': T.GenericMultiAddress.process,
        'generic_call': T.GenericCall.process,
        'era': T.Era.process,
        'scale_info_event': T.GenericScaleInfoEvent.process,
        'event_record': T.GenericEventRecord.process,
        'u8_class': P.U8,
    })


cdef _Node _build_node(rc, type_string, dict node_cache):
    cdef _Node node
    cdef object cached

    if not _KNOWN:
        _init_dispatch_tables()

    is_str = isinstance(type_string, str)
    if is_str:
        cached = node_cache.get(type_string)
        if cached is not None:
            return <_Node>cached

    cls = rc.get_decoder_class(type_string)
    if cls is None:
        raise UnsupportedType(f'Decoder class for "{type_string}" not found')

    node = _Node.__new__(_Node)
    if is_str:
        # Memoize before compiling children so recursive type graphs terminate;
        # a failed compile removes the placeholder again below.
        node_cache[type_string] = node

    try:
        _fill_node(node, rc, cls, node_cache)
    except BaseException:
        if is_str:
            node_cache.pop(type_string, None)
        raise
    return node


cdef _fill_node(_Node node, rc, cls, dict node_cache):
    """Populate `node` from decoder class `cls`, dispatching on which known base
    implementation provides its `process` (an overridden `process` means the
    type has custom semantics and is not supported)."""
    process = getattr(cls, 'process', None)
    if process is None:
        raise UnsupportedType(f'{cls!r} has no process method')

    op = _PRIM_OPS.get(process)
    if op is not None:
        node.op = op
        return

    if process is _KNOWN['account_id']:
        node.op = OP_ACCOUNT_ID
        node.aux = rc
        return
    if process is _KNOWN['h256']:
        node.op = OP_H256
        return
    if process is _KNOWN['bytes']:
        node.op = OP_BYTES
        return
    if process is _KNOWN['hexbytes']:
        node.op = OP_HEXBYTES
        return
    if process is _KNOWN['option_bytes']:
        node.op = OP_OPTION_BYTES
        return

    if process is _KNOWN['option']:
        node.op = OP_OPTION
        sub_type = cls.sub_type
        if sub_type:
            node.children = [_build_node(rc, sub_type, node_cache)]
        return

    if process is _KNOWN['vec']:
        sub_type = cls.sub_type
        if not sub_type:
            raise UnsupportedType(f'Vec without sub_type: {cls}')
        if rc.get_decoder_class(sub_type) is _KNOWN['u8_class']:
            node.op = OP_BYTES
            return
        node.op = OP_VEC
        node.children = [_build_node(rc, sub_type, node_cache)]
        return

    if process is _KNOWN['array']:
        sub_type = cls.sub_type
        count = cls.element_count or 0
        if count == 0 or rc.get_decoder_class(sub_type) is _KNOWN['u8_class']:
            # element_count 0 decodes to [] regardless of sub type
            node.op = OP_ARRAY_U8
            node.n = count
            return
        node.op = OP_ARRAY
        node.n = count
        node.children = [_build_node(rc, sub_type, node_cache)]
        return

    if process is _KNOWN['struct']:
        type_mapping = cls.type_mapping
        if type_mapping is None:
            # e.g. classes that assemble an instance-level type_mapping in __init__
            raise UnsupportedType(f'Struct without class-level type_mapping: {cls}')
        node.op = OP_STRUCT
        node.children = [
            _build_node(rc, field_type or 'Null', node_cache)
            for _, field_type in type_mapping
        ]
        node.keys = [field_name for field_name, _ in type_mapping]
        return

    if process is _KNOWN['tuple']:
        type_mapping = cls.type_mapping
        if type_mapping is None:
            raise UnsupportedType(f'Tuple without type_mapping: {cls}')
        if len(type_mapping) == 0:
            # the unit type (): decodes to an empty tuple, consuming nothing
            node.op = OP_TUPLE
            node.children = []
            return
        children = [
            _build_node(rc, member_type or 'Null', node_cache)
            for member_type in type_mapping
        ]
        node.op = OP_TUPLE1 if len(children) == 1 else OP_TUPLE
        node.children = children
        return

    if process is _KNOWN['multiaddress']:
        type_mapping = cls.type_mapping
        if not type_mapping:
            raise UnsupportedType(f'MultiAddress without type_mapping: {cls}')
        keys = []
        children = []
        for entry in type_mapping:
            variant_name, variant_type = entry[0], entry[1]
            keys.append(variant_name)
            if variant_type is None or variant_type == 'Null':
                children.append(None)
            else:
                children.append(_build_node(rc, variant_type, node_cache))
        node.op = OP_MULTIADDR
        node.keys = keys
        node.children = children
        return

    if process is _KNOWN['generic_call']:
        node.op = OP_CALL
        node.aux = _build_call_table(rc, cls, node_cache)
        return

    if process is _KNOWN['era']:
        node.op = OP_ERA
        return

    if process is _KNOWN['scale_info_event']:
        node.op = OP_EVENT
        node.aux = _build_event_table(rc, cls, node_cache)
        return

    if process is _KNOWN['event_record']:
        type_mapping = cls.type_mapping
        if (
            not type_mapping
            or len(type_mapping) != 3
            or [f[0] for f in type_mapping] != ['phase', 'event', 'topics']
        ):
            raise UnsupportedType(f'EventRecord with unexpected shape: {cls}')
        event_node = _build_node(rc, type_mapping[1][1], node_cache)
        if event_node.op != OP_EVENT:
            raise UnsupportedType(f'EventRecord event field is not a runtime event: {cls}')
        node.op = OP_EVENT_RECORD
        node.children = [
            _build_node(rc, type_mapping[0][1], node_cache),   # phase
            _build_node(rc, type_mapping[2][1], node_cache),   # topics
        ]
        node.aux = event_node.aux
        return

    if process is _KNOWN['enum']:
        type_mapping = cls.type_mapping
        if type_mapping:
            keys = []
            children = []
            for entry in type_mapping:
                variant_name, variant_type = entry[0], entry[1]
                keys.append(variant_name)
                if variant_type is None or variant_type == 'Null':
                    children.append(None)
                else:
                    children.append(_build_node(rc, variant_type, node_cache))
            node.op = OP_ENUM
            node.keys = keys
            node.children = children
            return
        value_list = cls.value_list
        if value_list:
            node.op = OP_ENUM_VALUES
            node.aux = list(value_list)
            return
        # uninhabited enum (e.g. Void): no variant can ever decode; any index
        # raises, exactly like the classic path
        node.op = OP_ENUM
        node.keys = []
        node.children = []
        return

    if process is _KNOWN['null']:
        node.op = OP_NULL
        return

    if process is _KNOWN['bitvec']:
        node.op = OP_BITVEC
        return

    if process is _KNOWN['btreemap']:
        node.op = OP_BTREEMAP
        node.children = [_build_map_pairs_node(rc, cls, node_cache)]
        return

    if process is _KNOWN['map']:
        node.op = OP_WRAP
        node.children = [_build_map_pairs_node(rc, cls, node_cache)]
        return

    if process is _KNOWN['btreeset']:
        type_mapping = getattr(cls, 'type_mapping', None)
        if not type_mapping:
            raise UnsupportedType(f'BTreeSet without type_mapping: {cls}')
        node.op = OP_WRAP
        node.children = [_build_node(rc, type_mapping[0], node_cache)]
        return

    if process is _KNOWN['set']:
        value_list = cls.value_list
        if not isinstance(value_list, dict) or not value_list:
            raise UnsupportedType(f'Set without value_list: {cls}')
        node.op = OP_SET
        node.aux = list(value_list.items())
        node.children = [_build_node(rc, cls.value_type or 'u64', node_cache)]
        return

    raise UnsupportedType(
        f'No value-decode support for {cls!r} (process from '
        f'{getattr(process, "__qualname__", process)!r})'
    )


cdef _Node _build_map_pairs_node(rc, cls, dict node_cache):
    """The list-of-(key, value) producer both Map and BTreeMap decode through."""
    cdef _Node vec_node, pair_node
    type_mapping = getattr(cls, 'type_mapping', None)
    if type_mapping:
        # scale_info shape: a single wrapped type (typically Vec<(K, V)>)
        return _build_node(rc, type_mapping[0], node_cache)
    sub_type = getattr(cls, 'sub_type', None)
    if not sub_type:
        raise UnsupportedType(f'Map without sub_type or type_mapping: {cls}')
    sub_type_parts = [x.strip() for x in sub_type.split(',')]
    if len(sub_type_parts) != 2:
        raise UnsupportedType(f'Map sub_type not a key/value pair: {sub_type!r}')
    pair_node = _Node.__new__(_Node)
    pair_node.op = OP_TUPLE
    pair_node.children = [
        _build_node(rc, sub_type_parts[0], node_cache),
        _build_node(rc, sub_type_parts[1], node_cache),
    ]
    vec_node = _Node.__new__(_Node)
    vec_node.op = OP_VEC
    vec_node.children = [pair_node]
    return vec_node


cdef dict _build_call_table(rc, cls, dict node_cache):
    """Compile the GenericCall decode table from the registry's RuntimeCall enum.

    Every name, converted type string, and sub-decoder is resolved once at
    compile time, so decoding a call is two table lookups plus its args.
    """
    from scalecodec.base import RuntimeConfigurationObject
    convert = RuntimeConfigurationObject.convert_type_string

    sit = getattr(cls, 'scale_info_type', None)
    if sit is None:
        raise UnsupportedType(f'Call class without scale_info_type: {cls}')
    d = sit['def']
    if d[0] != 'variant':
        raise UnsupportedType(f'Call registry def is not a variant: {cls}')

    cdef dict table = {}
    for variant in d[1].value_object['variants'].value_object:
        vv = variant.value
        fields = vv.get('fields') or []
        if len(fields) != 1:
            raise UnsupportedType(f'Call pallet variant {vv.get("name")!r} has unexpected shape')
        inner_cls = rc.get_decoder_class(f"scale_info::{fields[0]['type']}")
        inner_sit = getattr(inner_cls, 'scale_info_type', None)
        if inner_sit is None or inner_sit['def'][0] != 'variant':
            raise UnsupportedType(f'Pallet call enum for {vv.get("name")!r} is not a variant')

        inner_table = {}
        for call_variant in inner_sit['def'][1].value_object['variants'].value_object:
            cv = call_variant.value
            args = []
            for f in cv.get('fields') or []:
                if f.get('name') is None:
                    raise UnsupportedType(
                        f'Unnamed call arg in {vv.get("name")}.{cv.get("name")}'
                    )
                type_name = f.get('typeName')
                args.append((
                    f['name'],
                    convert(type_name) if type_name is not None else None,
                    _build_node(rc, f"scale_info::{f['type']}", node_cache),
                ))
            inner_table[cv['index']] = (cv['name'], args)

        table[vv['index']] = (vv['name'], inner_table)

    return table


cdef object _variant_payload_node(rc, fields, dict node_cache):
    """The decoder for one variant's payload: None (unit), a dict of named
    fields, a single unnamed value, or a tuple — matching Enum's shapes."""
    cdef _Node payload
    if not fields:
        return None
    if all(f.get('name') for f in fields):
        payload = _Node.__new__(_Node)
        payload.op = OP_STRUCT
        payload.keys = [f['name'] for f in fields]
        payload.children = [
            _build_node(rc, f"scale_info::{f['type']}", node_cache) for f in fields
        ]
        return payload
    if len(fields) == 1:
        return _build_node(rc, f"scale_info::{fields[0]['type']}", node_cache)
    payload = _Node.__new__(_Node)
    payload.op = OP_TUPLE
    payload.children = [
        _build_node(rc, f"scale_info::{f['type']}", node_cache) for f in fields
    ]
    return payload


cdef dict _build_event_table(rc, cls, dict node_cache):
    """Compile the runtime event decode table from the registry's RuntimeEvent
    enum: {pallet_index: (pallet_name, {event_index: (event_name, payload)})}."""
    sit = getattr(cls, 'scale_info_type', None)
    if sit is None:
        raise UnsupportedType(f'Event class without scale_info_type: {cls}')
    d = sit['def']
    if d[0] != 'variant':
        raise UnsupportedType(f'Event registry def is not a variant: {cls}')

    cdef dict table = {}
    for variant in d[1].value_object['variants'].value_object:
        vv = variant.value
        fields = vv.get('fields') or []
        if len(fields) != 1:
            raise UnsupportedType(f'Event pallet variant {vv.get("name")!r} has unexpected shape')
        inner_cls = rc.get_decoder_class(f"scale_info::{fields[0]['type']}")
        inner_sit = getattr(inner_cls, 'scale_info_type', None)
        if inner_sit is None or inner_sit['def'][0] != 'variant':
            raise UnsupportedType(f'Pallet event enum for {vv.get("name")!r} is not a variant')

        inner_table = {}
        for event_variant in inner_sit['def'][1].value_object['variants'].value_object:
            ev = event_variant.value
            inner_table[ev['index']] = (
                ev['name'],
                _variant_payload_node(rc, ev.get('fields') or [], node_cache),
            )

        table[vv['index']] = (vv['name'], inner_table)

    return table
