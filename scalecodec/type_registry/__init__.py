import os
import json
from typing import Optional

import requests

SUPPORTED_TYPE_REGISTRY_PRESETS = (
    "canvas",
    "legacy",
    "kusama",
    "polkadot",
    "rococo",
    "core",
    "substrate-node-template",
    "westend",
    "statemint",
    "statemine",
    "karura",
    "moonbeam",
    "moonriver",
    "moonbase-alpha",
    "crust",
    "polymesh-mainnet",
    "polymesh-testnet",
    "acala",
    "test",
    "contracts-on-rococo",
)

ONLINE_BASE_URL = "https://raw.githubusercontent.com/polkascan/py-scale-codec/v1.0/scalecodec/type_registry/"


def load_type_registry_preset(
    name: str, use_remote_preset: bool = False
) -> Optional[dict]:
    """
    Loads a type registry JSON file into a dict

    Parameters
    ----------
    name
    use_remote_preset: When True preset is downloaded from Github master, otherwise use files from local installed scalecodec package

    Returns
    -------

    """

    if name not in SUPPORTED_TYPE_REGISTRY_PRESETS:
        raise ValueError(f'Unsupported type registry preset "{name}"')

    if use_remote_preset is True:
        result = requests.get(f"{ONLINE_BASE_URL}{name}.json")

        if result.status_code == 200:
            return result.json()
    else:
        module_path = os.path.dirname(__file__)
        path = os.path.join(module_path, "{}.json".format(name))
        try:
            return load_type_registry_file(path)
        except FileNotFoundError:
            return None


def load_type_registry_file(file_path: str) -> dict:
    with open(os.path.abspath(file_path), "r") as fp:
        data = fp.read()

    return json.loads(data)
