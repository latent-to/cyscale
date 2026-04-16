import re
import warnings
from abc import ABC, abstractmethod
from functools import lru_cache
from typing import Any, Optional, TYPE_CHECKING, Union

from scalecodec.constants import TYPE_DECOMP_MAX_RECURSIVE
from scalecodec.exceptions import RemainingScaleBytesNotEmptyException, InvalidScaleTypeValueException
from scalecodec._scale_bytes import ScaleBytes


def _try_make_tuple_batch_decode(type_mapping, rc):
    """
    Generate a composite _batch_decode function for a Tuple/Struct if every
    sub-type has both _batch_decode and _fixed_size.  Returns None otherwise.
    """
    specs = []
    keys = []
    is_struct = type_mapping and isinstance(type_mapping[0], (list, tuple))
    for ts in type_mapping:
        if isinstance(ts, (list, tuple)):
            keys.append(ts[0])
            ts = ts[1]      # Struct field: [name, type_string]
        if ts is None:
            ts = 'Null'
        cls = rc.get_decoder_class(ts)
        if cls is None:
            return None
        fast_fn = getattr(cls, '_batch_decode', None)
        size    = getattr(cls, '_fixed_size',    None)
        if fast_fn is None or size is None:
            return None
        specs.append((fast_fn, size))

    total_size = sum(s for _, s in specs)

    if is_struct:
        _specs = specs
        _keys = keys

        def _batch_decode(data, __specs=_specs, __keys=_keys):
            result = {}
            offset = 0
            for (fast_fn, size), key in zip(__specs, __keys):
                result[key] = fast_fn(data[offset:])
                offset += size
            return result
    elif len(specs) == 1:
        _fn, _sz = specs[0]

        def _batch_decode(data, __fn=_fn):
            return __fn(data)
    else:
        _specs = specs

        def _batch_decode(data, __specs=_specs):
            result = []
            offset = 0
            for fast_fn, size in __specs:
                result.append(fast_fn(data[offset:]))
                offset += size
            return tuple(result)

    return _batch_decode, total_size

if TYPE_CHECKING:
    from scalecodec.types import GenericMetadataVersioned, GenericRegistryType


class Singleton(type):
    _instances = {}

    def __call__(cls, *args, **kwargs):

        if 'config_id' in kwargs:
            instance_key = kwargs['config_id']
        else:
            instance_key = cls

        if instance_key not in cls._instances:
            cls._instances[instance_key] = super(Singleton, cls).__call__(*args, **kwargs)
        return cls._instances[instance_key]


class RuntimeConfigurationObject:
    """
    Container for runtime configuration, for example type definitions and runtime upgrade information
    """

    @classmethod
    def all_subclasses(cls, class_) -> set:
        return set(class_.__subclasses__()).union(
            [s for c in class_.__subclasses__() for s in cls.all_subclasses(c)])

    def __init__(self, config_id: Optional[str] = None, ss58_format: Optional[int] = None, only_primitives_on_init: bool = False, implements_scale_info: bool = False):
        self.config_id = config_id
        self.type_registry = {'types': {}, 'runtime_api': {}}
        self._initial_state = False
        self.clear_type_registry()
        self.active_spec_version_id = None
        self.chain_id = None

        self.only_primitives_on_init = only_primitives_on_init
        self.ss58_format = ss58_format
        self.implements_scale_info = implements_scale_info
        self.arrow_match_re = re.compile(r'^([^<]*)<(.+)>$')
        self.bracket_match_re = re.compile(r'^\[([A-Za-z0-9]+); ([0-9]+)]$')
        self._dynamic_class_cache: dict = {}

    @classmethod
    @lru_cache(maxsize=128)
    def convert_type_string(cls, name: str) -> str:

        name = re.sub(r'T::', "", name)
        name = re.sub(r'^T::', "", name, flags=re.IGNORECASE)
        name = re.sub(r'<T>', "", name, flags=re.IGNORECASE)
        name = re.sub(r'<T as Trait>::', "", name, flags=re.IGNORECASE)
        name = re.sub(r'<T as Trait<I>>::', "", name, flags=re.IGNORECASE)
        name = re.sub(r'<T as Config>::', "", name, flags=re.IGNORECASE)
        name = re.sub(r'<T as Config<I>>::', "", name, flags=re.IGNORECASE)
        name = re.sub(r'\n', "", name)
        name = re.sub(r'^(grandpa|session|slashing|limits|beefy_primitives|xcm::opaque)::', "", name)
        name = re.sub(r'VecDeque<', "Vec<", name, flags=re.IGNORECASE)
        name = re.sub(r'^Box<(.+)>$', r'\1', name, flags=re.IGNORECASE)

        if name == '()':
            return "Null"
        if name.lower() in ['vec<u8>', '&[u8]', "& 'static[u8]"]:
            return "Bytes"
        if name.lower() == '<lookup as staticlookup>::source':
            return 'LookupSource'
        if name.lower() == '<balance as hascompact>::type':
            return 'Compact<Balance>'
        if name.lower() == '<blocknumber as hascompact>::type':
            return 'Compact<BlockNumber>'
        if name.lower() == '<moment as hascompact>::type':
            return 'Compact<Moment>'
        if name.lower() == '<inherentofflinereport as inherentofflinereport>::inherent':
            return 'InherentOfflineReport'

        return name

    def get_decoder_class(self, type_string: Union[str, dict]):
        """
        Lookup and return a ScaleDecoder class for given `type_string`

        Parameters
        ----------
        type_string

        Returns
        -------
        ScaleDecoder
        """

        if type(type_string) is dict:
            # Inner struct
            struct_base = self.get_decoder_class('Struct')
            assert struct_base is not None
            decoder_class = type('InnerStruct', (struct_base,), {
                'type_mapping': tuple(type_string.items())
            })
            decoder_class.runtime_config = self
            return decoder_class

        if type_string.strip() == '':
            return None

        if self.implements_scale_info is False:
            type_string = self.convert_type_string(type_string)

        decoder_class = self.type_registry.get('types', {}).get(type_string.lower(), None)

        if not decoder_class:
            # Check dynamic class cache before creating a new one
            decoder_class = self._dynamic_class_cache.get(type_string)

        if not decoder_class:
            # Type string containg subtype
            if type_string[-1:] == '>':

                # Extract sub types
                type_parts = self.arrow_match_re.match(type_string)

                if type_parts:
                    type_parts = type_parts.groups()

                if type_parts:
                    # Create dynamic class for Part1<Part2> based on Part1 and set class variable Part2 as sub_type
                    base_class = self.type_registry.get('types', {}).get(type_parts[0].lower(), None)
                    if base_class:
                        decoder_class = type(type_string, (base_class,), {'sub_type': type_parts[1]})

            # Custom tuples
            elif type_string != '()' and type_string[0] == '(' and type_string[-1] == ')':

                tuple_base = self.get_decoder_class('tuple')
                assert tuple_base is not None
                decoder_class = type(type_string, (tuple_base,), {
                    'type_string': type_string
                })

                decoder_class.build_type_mapping()

                _result = _try_make_tuple_batch_decode(decoder_class.type_mapping, self)
                if _result is not None:
                    decoder_class._batch_decode = staticmethod(_result[0])
                    decoder_class._fixed_size = _result[1]

                self._dynamic_class_cache[type_string] = decoder_class

            elif type_string[0] == '[' and type_string[-1] == ']':
                type_parts = self.bracket_match_re.match(type_string)

                if type_parts:
                    type_parts = type_parts.groups()

                if type_parts:
                    # Create dynamic class for e.g. [u8; 4] resulting in array of u8 with 4 elements
                    fixed_array_base = self.get_decoder_class('FixedLengthArray')
                    assert fixed_array_base is not None
                    decoder_class = type(type_string, (fixed_array_base,), {
                        'sub_type': type_parts[0],
                        'element_count': int(type_parts[1])
                    })
                    from scalecodec._primitives import U8 as _U8
                    _n = int(type_parts[1])
                    if self.get_decoder_class(type_parts[0]) is _U8:
                        if _n == 0:
                            decoder_class._batch_decode = staticmethod(lambda data: [])
                        else:
                            decoder_class._batch_decode = staticmethod(lambda data, n=_n: '0x' + data[:n].hex())
                        decoder_class._fixed_size = _n
                    self._dynamic_class_cache[type_string] = decoder_class

        if decoder_class:
            # Attach RuntimeConfigurationObject to new class
            decoder_class.runtime_config = self

        return decoder_class

    def _require_decoder_class(self, type_string: str):
        """Like get_decoder_class but raises instead of returning None."""
        cls = self.get_decoder_class(type_string)
        if cls is None:
            raise NotImplementedError(f"Decoder class for '{type_string}' not found")
        return cls

    def batch_decode(self, list type_strings, list data_list) -> list:
        """
        Decode N SCALE-encoded items with minimal per-item overhead.

        More efficient than N calls to create_scale_object().decode() because:
        - Each unique type class is resolved only once per batch call
        - Primitive types (u8–u256, i8–i256, bool) use direct struct.unpack /
          int.from_bytes fast paths, bypassing ScaleType object creation entirely

        Particularly effective for query_map batches where all values share
        one type string and all keys share another (2 class lookups for N items).
        """
        cdef int n = len(type_strings)
        cdef list results = [None] * n
        cdef dict local_cache = {}
        cdef int i
        cdef str ts
        cdef object decoder_class, fast_fn, entry, obj

        for i in range(n):
            ts = type_strings[i]
            entry = local_cache.get(ts)
            if entry is None:
                decoder_class = self.get_decoder_class(ts)
                if decoder_class is None:
                    raise NotImplementedError(f'Decoder class for "{ts}" not found')
                fast_fn = getattr(decoder_class, '_batch_decode', None)
                entry = (decoder_class, fast_fn)
                local_cache[ts] = entry
            else:
                decoder_class = entry[0]
                fast_fn = entry[1]

            data = data_list[i]
            if fast_fn is not None:
                results[i] = fast_fn(data)
            else:
                obj = decoder_class(data=ScaleBytes(data))
                obj.decode()
                results[i] = obj.value

        return results

    def create_scale_object(self, type_string: Union[str, dict], data: Optional['ScaleBytes'] = None, **kwargs) -> 'ScaleType':
        """
        Creates a new `ScaleType` object with given type_string, for example 'u32', 'Bytes' or 'scale_info::2'
        (scale_info:: prefixed types are defined in the `PortableRegistry` object of the runtime metadata.)

        Parameters
        ----------
        type_string: string representation of a `ScaleType`
        data: ScaleBytes data to decode
        kwargs

        Returns
        -------
        ScaleType
        """
        decoder_class = self.get_decoder_class(type_string)

        if decoder_class:
            return decoder_class(data=data, **kwargs)

        raise NotImplementedError('Decoder class for "{}" not found'.format(type_string))

    def clear_type_registry(self) -> None:

        if not self._initial_state:
            self.type_registry = {'types': {}, 'runtime_api': {}}

            # Class names that contains '<' are excluded because of a side effect that is introduced in
            # get_decoder_class: "Create dynamic class for Part1<Part2> based on Part1 and set class variable Part2 as
            # sub_type" which won't get reset because class definitions always remain globally

            self.type_registry['types'].update(
                {
                    cls.__name__.lower(): cls for cls in self.all_subclasses(ScaleDecoder)
                    if '<' not in cls.__name__ and '::' not in cls.__name__
                }
            )

        self._initial_state = True

    def update_type_registry_types(self, types_dict: dict) -> None:
        from scalecodec.types import Enum, Struct, Set, Tuple

        self._initial_state = False

        for type_string, decoder_class_data in types_dict.items():

            if type(decoder_class_data) == dict:

                # Create dynamic decoder class
                base_cls = None

                if decoder_class_data.get('base_class'):
                    base_cls = self.get_decoder_class(decoder_class_data['base_class'])
                    if base_cls is None:
                        raise ValueError(f"Specified base_class '{decoder_class_data['base_class']}' for type " +
                                         f"'{type_string}' not found")

                if decoder_class_data['type'] == 'struct':

                    if base_cls is None:
                        base_cls = Struct

                    decoder_class = type(type_string, (base_cls,), {
                        'type_mapping': decoder_class_data.get('type_mapping')
                    })

                elif decoder_class_data['type'] == 'tuple':

                    if base_cls is None:
                        base_cls = Tuple

                    decoder_class = type(type_string, (base_cls,), {
                        'type_mapping': decoder_class_data.get('type_mapping')
                    })

                elif decoder_class_data['type'] == 'enum':

                    if base_cls is None:
                        base_cls = Enum

                    value_list = decoder_class_data.get('value_list')

                    if type(value_list) is dict:
                        # Transform value_list with explicitly specified index numbers
                        value_list = {i: v for v, i in value_list.items()}

                    decoder_class = type(type_string, (base_cls,), {
                        'value_list': value_list,
                        'type_mapping': decoder_class_data.get('type_mapping')
                    })

                elif decoder_class_data['type'] == 'set':

                    if base_cls is None:
                        base_cls = Set

                    decoder_class = type(type_string, (base_cls,), {
                        'value_list': decoder_class_data.get('value_list'),
                        'value_type': decoder_class_data.get('value_type', 'u64')
                    })

                else:
                    raise NotImplementedError("Dynamic decoding type '{}' not supported".format(
                        decoder_class_data['type'])
                    )
            else:
                decoder_class = self.get_decoder_class(decoder_class_data)

            self.type_registry['types'][type_string.lower()] = decoder_class

    def update_type_registry(self, type_registry: dict) -> None:

        # Set runtime ID if set
        self.active_spec_version_id = type_registry.get('runtime_id')

        # Set chain ID if set
        self.chain_id = type_registry.get('chain_id')

        self.type_registry['versioning'] = type_registry.get('versioning')
        self.type_registry['runtime_api'].update(type_registry.get('runtime_api', {}))
        self.type_registry['runtime_upgrades'] = type_registry.get('runtime_upgrades')

        # Update types
        if 'types' in type_registry:
            self.update_type_registry_types(type_registry.get('types'))

    def set_active_spec_version_id(self, spec_version_id: int) -> None:

        if spec_version_id != self.active_spec_version_id:

            self.active_spec_version_id = spec_version_id

            # Updated type registry with versioned types
            for versioning_item in self.type_registry.get('versioning') or []:
                # Check if versioning item is in current version range
                if versioning_item['runtime_range'][0] <= spec_version_id and \
                        (not versioning_item['runtime_range'][1] or versioning_item['runtime_range'][1] >= spec_version_id):
                    # Update types in type registry
                    self.update_type_registry_types(versioning_item['types'])

    def get_runtime_id_from_upgrades(self, block_number: int) -> Optional[int]:
        """
        Retrieve runtime_id for given block_number if runtime_upgrades are specified in the type registry

        Parameters
        ----------
        block_number

        Returns
        -------
        Runtime id
        """
        if self.type_registry.get('runtime_upgrades'):
            upgrades = self.type_registry['runtime_upgrades']
            if block_number > upgrades[len(upgrades) - 1][0]:
                return None

            for max_block_number, runtime_id in reversed(self.type_registry['runtime_upgrades']):
                if block_number >= max_block_number and runtime_id != -1:
                    return runtime_id

    def set_runtime_upgrades_head(self, block_number: int):
        """
        Sets head for given block_number to last runtime_id in runtime_upgrades cache

        Parameters
        ----------
        block_number

        Returns
        -------

        """
        if self.type_registry.get('runtime_upgrades'):
            upgrades = self.type_registry['runtime_upgrades']
            last = len(upgrades) - 1
            if upgrades[last][1] == -1:
                upgrades[last][0] = block_number
            elif block_number > upgrades[last][0]:
                upgrades.append([block_number, -1])

    def get_decoder_class_for_scale_info_definition(
            self, type_string: str, scale_info_type: 'GenericRegistryType', prefix: str
    ):
        # Check if this class was already created and cached
        if type_string in self._dynamic_class_cache:
            return self._dynamic_class_cache[type_string]

        decoder_class = None
        base_decoder_class = None

        # Check if base decoder class is defined for path
        if 'path' in scale_info_type.value and len(scale_info_type.value['path']) > 0:
            path_string = '::'.join(scale_info_type.value["path"])
            base_decoder_class = self.get_decoder_class(path_string)

            if base_decoder_class is None:

                # Try wildcard type
                catch_all_path = '*::' + '::'.join(scale_info_type.value["path"][1:])
                base_decoder_class = self.get_decoder_class(catch_all_path)

                if base_decoder_class is None:
                    # Try catch-all type
                    _path = scale_info_type.value["path"]
                    catch_all_path = '*::' * (len(_path) - 1) + _path[len(_path) - 1]
                    base_decoder_class = self.get_decoder_class(catch_all_path)

            if base_decoder_class and hasattr(base_decoder_class, 'process_scale_info_definition'):
                # if process_scale_info_definition is implemented result is final
                decoder_class = type(type_string, (base_decoder_class,), {})  # type: ignore[arg-type]
                decoder_class.process_scale_info_definition(scale_info_type, prefix)  # type: ignore[attr-defined]

                # Link ScaleInfo RegistryType to decoder class
                decoder_class.scale_info_type = scale_info_type  # type: ignore[attr-defined]

                # Cache the dynamically created class
                self._dynamic_class_cache[type_string] = decoder_class

                return decoder_class

        if "primitive" in scale_info_type.value["def"]:
            decoder_class = self.get_decoder_class(scale_info_type.value["def"]["primitive"])

        elif 'array' in scale_info_type.value['def']:

            if base_decoder_class is None:
                base_decoder_class = self._require_decoder_class('FixedLengthArray')

            decoder_class = type(type_string, (base_decoder_class,), {  # type: ignore[arg-type]
                'sub_type': f"{prefix}::{scale_info_type.value['def']['array']['type']}",
                'element_count': scale_info_type.value['def']['array']['len']
            })
            from scalecodec._primitives import U8 as _U8
            _n = scale_info_type.value['def']['array']['len']
            _sub_cls = self.get_decoder_class(f"{prefix}::{scale_info_type.value['def']['array']['type']}")
            if _sub_cls is _U8:
                if _n == 0:
                    decoder_class._batch_decode = staticmethod(lambda data: [])
                else:
                    decoder_class._batch_decode = staticmethod(lambda data, n=_n: '0x' + data[:n].hex())
                decoder_class._fixed_size = _n

        elif 'composite' in scale_info_type.value['def']:

            type_mapping = []

            base_type_string = 'Tuple'

            if 'fields' in scale_info_type.value['def']['composite']:

                fields = scale_info_type.value['def']['composite']['fields']

                if all([f.get('name') for f in fields]):
                    base_type_string = 'Struct'
                    type_mapping = [[field['name'], f"{prefix}::{field['type']}"] for field in fields]

                else:
                    base_type_string = 'Tuple'
                    type_mapping = [f"{prefix}::{field['type']}" for field in fields]

            if base_decoder_class is None:
                base_decoder_class = self._require_decoder_class(base_type_string)

            decoder_class = type(type_string, (base_decoder_class,), {  # type: ignore[arg-type]
                'type_mapping': type_mapping
            })
            _result = _try_make_tuple_batch_decode(type_mapping, self)
            if _result is not None:
                decoder_class._batch_decode = staticmethod(_result[0])
                decoder_class._fixed_size = _result[1]

        elif 'sequence' in scale_info_type.value['def']:
            # Vec
            decoder_class = type(type_string, (self._require_decoder_class('Vec'),), {
                'sub_type': f"{prefix}::{scale_info_type.value['def']['sequence']['type']}"
            })

        elif 'variant' in scale_info_type.value['def']:
            # Enum
            type_mapping = []

            variants = scale_info_type.value['def']['variant']['variants']

            if len(variants) > 0:
                # Create placeholder list
                variant_length = max([v['index'] for v in variants]) + 1
                type_mapping = [(None, 'Null')] * variant_length

                for variant in variants:

                    if 'fields' in variant:
                        if len(variant['fields']) == 0:
                            enum_value = 'Null'
                        elif all([f.get('name') for f in variant['fields']]):
                            # Enum with named fields
                            enum_value = {f.get('name'): f"{prefix}::{f['type']}" for f in variant['fields']}
                        else:
                            if len(variant['fields']) == 1:
                                enum_value = f"{prefix}::{variant['fields'][0]['type']}"
                            else:
                                field_str = ', '.join([f"{prefix}::{f['type']}" for f in variant['fields']])
                                enum_value = f"({field_str})"
                    else:
                        enum_value = 'Null'

                    # Put mapping in right order in list
                    type_mapping[variant['index']] = (variant['name'], enum_value)

            if base_decoder_class is None:
                base_decoder_class = self._require_decoder_class("Enum")

            decoder_class = type(type_string, (base_decoder_class,), {  # type: ignore[arg-type]
                'type_mapping': type_mapping
            })

        elif 'tuple' in scale_info_type.value['def']:

            type_mapping = [f"{prefix}::{f}" for f in scale_info_type.value['def']['tuple']]

            decoder_class = type(type_string, (self._require_decoder_class('Tuple'),), {
                'type_mapping': type_mapping
            })
            _result = _try_make_tuple_batch_decode(type_mapping, self)
            if _result is not None:
                decoder_class._batch_decode = staticmethod(_result[0])
                decoder_class._fixed_size = _result[1]

        elif 'compact' in scale_info_type.value['def']:
            # Compact
            decoder_class = type(type_string, (self._require_decoder_class('Compact'),), {
                'sub_type': f"{prefix}::{scale_info_type.value['def']['compact']['type']}"
            })

        elif 'phantom' in scale_info_type.value['def']:
            decoder_class = type(type_string, (self._require_decoder_class('Null'),), {})

        elif 'bitsequence' in scale_info_type.value['def']:
            decoder_class = type(type_string, (self._require_decoder_class('BitVec'),), {})

        else:
            raise NotImplementedError(f"RegistryTypeDef {scale_info_type.value['def']} not implemented")

        # if 'path' in scale_info_type.value:
        #     decoder_class.type_string = '::'.join(scale_info_type.value['path'])

        # Link ScaleInfo RegistryType to decoder class

        decoder_class.scale_info_type = scale_info_type  # type: ignore[attr-defined]

        # Cache the dynamically created class
        self._dynamic_class_cache[type_string] = decoder_class

        return decoder_class

    def update_from_scale_info_types(self, scale_info_types: list, prefix: Optional[str] = None) -> None:

        if prefix is None:
            prefix = 'scale_info'

        for scale_info_type in scale_info_types:

            idx = scale_info_type['id'].value

            type_string = f"{prefix}::{idx}"

            decoder_class = self.get_decoder_class_for_scale_info_definition(
                type_string, scale_info_type['type'], prefix
            )

            if decoder_class is None:
                raise NotImplementedError(f"No decoding class found for scale type {idx}")

            if decoder_class:
                self.type_registry['types'][type_string] = decoder_class

                if len(scale_info_type['type'].value.get('path', [])) > 0:
                    path_string = '::'.join(scale_info_type['type'].value['path']).lower()
                    self.type_registry['types'][path_string] = decoder_class

    def add_portable_registry(self, metadata: 'GenericMetadataVersioned', prefix: Optional[str] = None) -> None:

        if prefix is None:
            prefix = 'scale_info'

        scale_info_types = metadata.portable_registry.value_object['types'].value_object

        # Clear cached classes for this prefix so that switching metadata (e.g. querying
        # a historical block) always rebuilds decoder classes from the new metadata rather
        # than returning stale classes built from a different runtime version.
        prefix_key = prefix + '::'
        stale_keys = [k for k in self._dynamic_class_cache if k.startswith(prefix_key)]
        for k in stale_keys:
            del self._dynamic_class_cache[k]

        self.update_from_scale_info_types(scale_info_types, prefix=prefix)

        # Process extrinsic type in metadata to register correct Address and ExtrinsicSignature types
        try:
            # Retrieve Extrinsic using common namespace
            extrinsic_type = self.get_decoder_class("sp_runtime::generic::unchecked_extrinsic::UncheckedExtrinsic")

            # Try to fall back on extrinsic type in metadata
            if extrinsic_type is None:
                extrinsic_type_id = metadata[1][1]['extrinsic']['ty'].value
                extrinsic_type = self.get_decoder_class(f"{prefix}::{extrinsic_type_id}")

            if extrinsic_type is not None:
                # Extract Address and Signature type and set in type registry

                types_dict = {}

                for param in extrinsic_type.scale_info_type.value['params']:
                    if param['name'] == 'Address':

                        type_string = f'{prefix}::{param["type"]}'

                        types_dict['Address'] = type_string
                        types_dict['AccountId'] = type_string
                        types_dict['LookupSource'] = type_string

                        # Check if Address is MultiAddress
                        addres_type = self.get_decoder_class(type_string)

                        if addres_type is self.get_decoder_class('sp_runtime::multiaddress::MultiAddress'):
                            for address_param in addres_type.scale_info_type.value['params']:  # type: ignore[union-attr]
                                if address_param['name'] == 'AccountId':
                                    # Set AccountId
                                    types_dict['AccountId'] = f'{prefix}::{address_param["type"]}'

                    elif param['name'] == 'Signature':
                        types_dict['ExtrinsicSignature'] = f'{prefix}::{param["type"]}'

                # Update type registry
                self.update_type_registry_types(types_dict)
        except NotImplementedError:
            pass

    def add_contract_metadata_dict_to_type_registry(self, metadata_dict: dict):
        # TODO
        prefix = f"ink::{metadata_dict['source']['hash']}"
        return self.update_from_scale_info_types(metadata_dict['types'], prefix=prefix)



class ScaleDecoder(ABC):
    """
    Base class for all SCALE decoding/encoding
    """

    type_string: Optional[str] = None

    type_mapping: Any = None

    sub_type: Optional[str] = None

    runtime_config = None

    def __init__(self, data: ScaleBytes, sub_type: Optional[str] = None, runtime_config: Optional[RuntimeConfigurationObject] = None):
        """
        Constructs an SCALE codec class capable of encoding and decoding SCALE-bytes

        Parameters
        ----------
        data: ScaleBytes stream of SCALE data
        sub_type
        runtime_config
        """
        if sub_type:
            self.sub_type = sub_type

        if self.type_mapping is None and self.type_string:
            self.build_type_mapping()

        if data:
            assert isinstance(data, ScaleBytes)

        if runtime_config:
            self.runtime_config = runtime_config

        if not self.runtime_config:
            # if no runtime config is provided, fallback on singleton
            self.runtime_config = RuntimeConfiguration()

        self.data = data

        self.value_object = None
        self.value_serialized = None

        self.decoded = False

        self.data_start_offset = None
        self.data_end_offset = None

    @property
    def value(self):
        # TODO fix
        # if not self.decoded:
        #     self.decode()
        return self.value_serialized

    @value.setter
    def value(self, value):
        self.value_serialized = value

    @staticmethod
    def is_primitive(type_string: str) -> bool:
        return type_string in ('bool', 'u8', 'u16', 'u32', 'u64', 'u128', 'u256', 'i8', 'i16', 'i32', 'i64', 'i128',
                               'i256', 'h160', 'h256', 'h512', '[u8; 4]', '[u8; 4]', '[u8; 8]', '[u8; 16]', '[u8; 32]',
                               '&[u8]')

    @classmethod
    def build_type_mapping(cls):

        if cls.type_string and cls.type_string[0] == '(' and cls.type_string[-1] == ')':
            type_mapping = ()

            tuple_contents = cls.type_string[1:-1]

            # replace subtype types
            sub_types = re.search(r'([A-Za-z]+<[^>]*>)', tuple_contents)
            if sub_types:
                sub_types = sub_types.groups()
                for sub_type in sub_types:
                    tuple_contents = tuple_contents.replace(sub_type, sub_type.replace(',', '|'))

            for tuple_element in tuple_contents.split(','):
                type_mapping += (tuple_element.strip().replace('|', ','),)

            cls.type_mapping = type_mapping

    def get_next_bytes(self, length: int) -> bytearray:
        """
        Retrieve `length` amount of bytes of the SCALE-bytes stream

        Parameters
        ----------
        length: amount of requested bytes

        Returns
        -------
        bytearray
        """
        data = self.data.get_next_bytes(length)
        return data

    def get_next_u8(self) -> int:
        """
        Retrieves the next byte and convert to an int

        Returns
        -------
        int
        """
        return int.from_bytes(self.get_next_bytes(1), byteorder='little')

    def get_next_bool(self) -> bool:
        """
        Retrieves the next byte and convert to an bool

        Returns
        -------
        bool
        """
        data = self.get_next_bytes(1)
        if data not in [b'\x00', b'\x01']:
            raise InvalidScaleTypeValueException('Invalid value for datatype "bool"')
        return data == b'\x01'

    def get_remaining_bytes(self) -> bytearray:
        """
        Retrieves all remaining bytes from the stream

        Returns
        -------
        bytearray
        """
        data = self.data.get_remaining_bytes()
        return data

    def get_used_bytes(self) -> bytearray:
        """
        Returns a bytearray of all SCALE-bytes used in the decoding process

        Returns
        -------
        bytearray
        """
        return self.data.data[self.data_start_offset:self.data_end_offset]

    @abstractmethod
    def process(self):
        """
        Implementation of the decoding process

        Returns
        -------

        """
        raise NotImplementedError

    def decode(self, data: Optional[ScaleBytes] = None, check_remaining: bool = True) -> Any:
        """
        Decodes available SCALE-bytes according to type specification of this ScaleType

        If no `data` is provided, it will try to decode data specified during init

        If `check_remaining` is enabled, an exception will be raised when data is remaining after decoding

        Parameters
        ----------
        data
        check_remaining: If enabled, an exception will be raised when data is remaining after decoding

        Returns
        -------

        """

        if data is not None:
            self.decoded = False
            self.data = data

        if not self.decoded:

            self.data_start_offset = self.data.offset
            self.value_serialized = self.process()
            self.decoded = True

            if self.value_object is None:
                # Default for value_object if not explicitly defined
                self.value_object = self.value_serialized

            self.data_end_offset = self.data.offset

            if check_remaining and self.data.offset != self.data.length:
                raise RemainingScaleBytesNotEmptyException(
                    f'Decoding <{self.__class__.__name__}> - Current offset: {self.data.offset} / length: {self.data.length}'
                )

            if self.data.offset > self.data.length:
                raise RemainingScaleBytesNotEmptyException(
                    f'Decoding <{self.__class__.__name__}> - No more bytes available (needed: {self.data.offset} / total: {self.data.length})'
                )

        return self.value

    def __str__(self):
        return str(self.serialize()) or ''

    def __repr__(self):
        return "<{}(value={})>".format(self.__class__.__name__, self.serialize())

    def encode(self, value: Any = None) -> ScaleBytes:
        """
        Encodes the serialized `value` representation of current `ScaleType` to a `ScaleBytes` stream

        Parameters
        ----------
        value

        Returns
        -------
        ScaleBytes
        """

        if value and issubclass(self.__class__, value.__class__):
            # Accept instance of current class directly
            self.data = value.data
            self.value_object = value.value_object
            self.value_serialized = value.value_serialized
            return value.data

        if value is not None:
            self.value_serialized = value
            self.decoded = True

        self.data = self.process_encode(self.value_serialized)

        if self.value_object is None:
            self.value_object = self.value_serialized

        return self.data

    def process_encode(self, value) -> ScaleBytes:
        """
        Implementation of the encoding process

        Parameters
        ----------
        value

        Returns
        -------
        ScaleBytes
        """
        raise NotImplementedError("Encoding not implemented for this ScaleType")

    @classmethod
    def get_decoder_class(cls, type_string, data=None, runtime_config=None, **kwargs):
        """
        Retrieves the decoding class for provided `type_string`

        Parameters
        ----------
        type_string
        data
        runtime_config
        kwargs

        Returns
        -------
        ScaleType
        """

        warnings.warn("Use RuntimeConfigurationObject.create_scale_object() instead", DeprecationWarning)

        if not runtime_config:
            runtime_config = RuntimeConfiguration()

        decoder_class = runtime_config.get_decoder_class(
            type_string
        )
        if decoder_class:
            return decoder_class(data=data, runtime_config=runtime_config, **kwargs)

        raise NotImplementedError('Decoder class for "{}" not found'.format(type_string))

    # TODO rename to decode_type (confusing when encoding is introduced)
    def process_type(self, type_string: Union[str, dict], **kwargs) -> 'ScaleType':
        obj = self.runtime_config.create_scale_object(type_string, self.data, **kwargs)
        obj.decode(check_remaining=False)
        return obj

    def serialize(self) -> Any:
        """
        Returns a serialized representation of current ScaleType

        Returns
        -------

        """
        return self.value_serialized

    @classmethod
    def convert_type(cls, name):
        return RuntimeConfigurationObject.convert_type_string(name)


class RuntimeConfiguration(RuntimeConfigurationObject, metaclass=Singleton):
    pass


class ScaleType(ScaleDecoder, ABC):
    """
    Base class for all SCALE types
    """
    scale_info_type: 'GenericRegistryType' = None

    def __init__(self, data: Optional[ScaleBytes] = None, sub_type: Optional[str] = None, metadata: Optional['GenericMetadataVersioned'] = None, runtime_config: Optional[RuntimeConfigurationObject] = None):
        """

        Initializes an `ScaleType`

        Parameters
        ----------
        data: ScaleBytes
        sub_type: str
        metadata: VersionedMetadata
        runtime_config: RuntimeConfigurationObject
        """
        self.metadata = metadata
        self.meta_info = None  # lazily initialized to {} on first access

        if not data:
            data = ScaleBytes(bytearray())
        super().__init__(data, sub_type, runtime_config=runtime_config)

    @property
    def meta_info(self):
        if self._meta_info is None:
            self._meta_info = {}
        return self._meta_info

    @meta_info.setter
    def meta_info(self, value):
        self._meta_info = value

    def __class_getitem__(cls, item):
        return cls

    def __getitem__(self, item):
        return self.value_object[item]

    def __iter__(self):
        for item in self.value_object:
            yield item

    def __eq__(self, other):
        if isinstance(other, ScaleType):
            return other.value_serialized == self.value_serialized
        else:
            return other == self.value_serialized

    def __gt__(self, other):
        if isinstance(other, ScaleType):
            return self.value_serialized > other.value_serialized
        else:
            return self.value_serialized > other

    def __ge__(self, other):
        if isinstance(other, ScaleType):
            return self.value_serialized >= other.value_serialized
        else:
            return self.value_serialized >= other

    def __lt__(self, other):
        if isinstance(other, ScaleType):
            return self.value_serialized < other.value_serialized
        else:
            return self.value_serialized < other

    def __le__(self, other):
        if isinstance(other, ScaleType):
            return self.value_serialized <= other.value_serialized
        else:
            return self.value_serialized <= other

    @classmethod
    def generate_type_decomposition(cls, _recursion_level: int = 0, max_recursion: int = TYPE_DECOMP_MAX_RECURSIVE):
        return cls.__name__


class ScalePrimitive(ScaleType, ABC):
    """
    A SCALE representation of a RUST primitive
    """
    @classmethod
    def generate_type_decomposition(cls, _recursion_level: int = 0, max_recursion: int = TYPE_DECOMP_MAX_RECURSIVE):
        return cls.__name__.lower()


