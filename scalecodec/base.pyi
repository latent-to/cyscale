from abc import ABC, abstractmethod
from typing import Any, Optional, Union, overload
from typing import Literal

from scalecodec._scale_bytes import ScaleBytes

class ScaleDecoder(ABC):
    runtime_config: RuntimeConfigurationObject
    data: Optional[ScaleBytes]
    value: Any

    @abstractmethod
    def process(self) -> Any: ...
    def decode(self, check_remaining: bool = True) -> Any: ...
    def encode(self, value: Any) -> ScaleBytes: ...

class ScaleType(ScaleDecoder, ABC): ...

class RuntimeConfigurationObject:
    config_id: Optional[str]
    ss58_format: Optional[int]
    implements_scale_info: bool
    type_registry: dict

    def __init__(
        self,
        config_id: Optional[str] = None,
        ss58_format: Optional[int] = None,
        only_primitives_on_init: bool = False,
        implements_scale_info: bool = False,
    ) -> None: ...
    def get_decoder_class(
        self, type_string: Union[str, dict]
    ) -> Optional[type[ScaleType]]: ...
    def batch_decode(
        self, type_strings: list[str], data_list: list[bytes]
    ) -> list[Any]: ...
    def update_type_registry(self, type_registry: dict) -> None: ...
    def update_type_registry_types(self, types_dict: dict) -> None: ...
    def clear_type_registry(self) -> None: ...
    def add_portable_registry(self, metadata: Any) -> None: ...
    @overload
    def create_scale_object(
        self,
        type_string: Literal["MetadataVersioned"],
        data: Optional[ScaleBytes] = None,
        **kwargs: Any,
    ) -> "GenericMetadataVersioned": ...
    @overload
    def create_scale_object(
        self,
        type_string: Literal["MetadataV14", "MetadataV15"],
        data: Optional[ScaleBytes] = None,
        **kwargs: Any,
    ) -> "GenericMetadataAll": ...
    @overload
    def create_scale_object(
        self,
        type_string: Union[str, dict],
        data: Optional[ScaleBytes] = None,
        **kwargs: Any,
    ) -> ScaleType: ...

class RuntimeConfiguration(RuntimeConfigurationObject): ...

# Imported here so callers only need `from scalecodec.base import ...`
from scalecodec.types import GenericMetadataVersioned as GenericMetadataVersioned
from scalecodec.types import GenericMetadataAll as GenericMetadataAll
