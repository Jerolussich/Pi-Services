"""Parse Itaú account statement PDFs into transaction dicts.

Expected layout (pdftotext -layout output):
    DDMMM  TIPO              DESCRIPCION          DEBIT       CREDIT      BALANCE

Each page covers one account/currency (URGP = UYU, US.D = USD).
Debit vs credit is determined by horizontal position of the amount.
"""
import re
import subprocess
from datetime import datetime
from hashlib import sha1

from .base import BankMismatchError

BANK_ID = "itau"
BANK_LABEL = "Itaú"
ITAU_MARKERS = ("Itaú", "ITAU", "itau.com.uy", "519157")

MONTHS = {
    "ENE": 1, "FEB": 2, "MAR": 3, "ABR": 4, "MAY": 5, "JUN": 6,
    "JUL": 7, "AGO": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DIC": 12,
}
CURRENCY_MAP = {"URGP": "UYU", "US.D": "USD", "USD": "USD", "UYU": "UYU"}
DATE_RE     = re.compile(r"^(\d{2})([A-Z]{3})\b")
STMT_DATE_RE = re.compile(r"(\d{2})([A-Z]{3})(\d{4})")
CURR_RE      = re.compile(r"519157\s+(\S+)")
NUMBER_RE    = re.compile(r"[\d]{1,3}(?:\.[\d]{3})*,\d{2}")
SKIP_TYPES   = {"SDO.APERTURA", "SDO. CIERRE", "SDO.CIERRE"}


def _parse_uy_number(s: str) -> float:
    return float(s.replace(".", "").replace(",", "."))


def _extract_text(pdf_path: str) -> str:
    result = subprocess.run(
        ["pdftotext", "-layout", pdf_path, "-"],
        capture_output=True, check=True, text=True,
    )
    return result.stdout


def _parse_page(page_text: str, account: str = "") -> list[dict]:
    currency = None
    stmt_year = datetime.now().year
    stmt_month = datetime.now().month

    for line in page_text.splitlines():
        m = CURR_RE.search(line)
        if m and m.group(1) in CURRENCY_MAP:
            currency = CURRENCY_MAP[m.group(1)]
        m = STMT_DATE_RE.search(line)
        if m and m.group(2) in MONTHS:
            stmt_month = MONTHS[m.group(2)]
            stmt_year = int(m.group(3))

    if not currency:
        return []

    txs = []
    same_day_counter: dict[str, int] = {}
    for raw_line in page_text.splitlines():
        m = DATE_RE.match(raw_line)
        if not m:
            continue
        day = int(m.group(1))
        mon_abbr = m.group(2)
        if mon_abbr not in MONTHS:
            continue
        month = MONTHS[mon_abbr]
        year = stmt_year - 1 if month > stmt_month else stmt_year
        try:
            tx_date = datetime(year, month, day)
        except ValueError:
            continue

        numbers = [(mm.group(0), mm.start()) for mm in NUMBER_RE.finditer(raw_line)]
        if len(numbers) < 2:
            continue

        amount_str, amount_pos = numbers[-2]
        balance_str, _          = numbers[-1]
        amount  = _parse_uy_number(amount_str)
        balance = _parse_uy_number(balance_str)

        body = raw_line[:amount_pos].rstrip()
        body_after_date = body[len(m.group(0)):].strip()

        parts = re.split(r"\s{2,}", body_after_date, maxsplit=1)
        if len(parts) == 2:
            mov_type, merchant = parts[0].strip(), parts[1].strip()
        else:
            mov_type, merchant = parts[0].strip(), ""
        if mov_type.upper() in SKIP_TYPES:
            continue

        direction = "debit" if amount_pos < 90 else "credit"

        date_key = tx_date.strftime("%Y-%m-%d")
        same_day_counter[date_key] = same_day_counter.get(date_key, 0) + 1
        idx = same_day_counter[date_key]

        uid_raw = f"{account}|{date_key}|{currency}|{mov_type}|{merchant}|{amount}|{idx}"
        ext_id = "pdf:" + sha1(uid_raw.encode()).hexdigest()[:16]

        txs.append({
            "external_id":  ext_id,
            "date":         tx_date.isoformat(),
            "movement":     mov_type,
            "merchant":     merchant,
            "amount":       amount,
            "currency":     currency,
            "direction":    direction,
            "balance":      balance,
            "account":      account,
        })
    return txs


def parse_pdf(pdf_path: str, account: str = "") -> list[dict]:
    text = _extract_text(pdf_path)
    if not any(marker in text for marker in ITAU_MARKERS):
        raise BankMismatchError(
            "This PDF does not look like an Itaú statement "
            "(no Itaú markers found). Pick the right bank in the upload form."
        )
    pages = text.split("\f")
    out: list[dict] = []
    for page in pages:
        out.extend(_parse_page(page, account=account))
    return out


if __name__ == "__main__":
    import json, sys
    account = sys.argv[2] if len(sys.argv) > 2 else ""
    txs = parse_pdf(sys.argv[1], account=account)
    print(json.dumps(txs, indent=2, ensure_ascii=False))
    print(f"\nTotal: {len(txs)} transactions")
