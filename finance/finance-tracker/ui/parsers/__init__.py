"""Bank-specific PDF parsers.

Each parser module exposes:
    BANK_ID     — stable key used by the UI (e.g. "itau")
    BANK_LABEL  — human-readable label shown in the UI (e.g. "Itaú")
    parse_pdf(pdf_path, account="") -> list[dict]

To add a new bank: create `ui/parsers/<bank>.py` with those symbols and add
the module to `_MODULES` below.
"""
from . import itau
from .base import BankMismatchError

_MODULES = (itau,)

PARSERS = {m.BANK_ID: m for m in _MODULES}
BANKS = [(m.BANK_ID, m.BANK_LABEL) for m in _MODULES]


def get_parser(bank_id: str):
    return PARSERS.get(bank_id)


__all__ = ["BankMismatchError", "PARSERS", "BANKS", "get_parser"]
