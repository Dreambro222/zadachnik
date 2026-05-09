from decimal import Decimal


def fmt_ton(nanotons: int) -> str:
    return f"{Decimal(nanotons) / Decimal(10**9):.4f} TON"


def fmt_amount(raw: int, decimals: int, symbol: str = "") -> str:
    if decimals <= 0:
        v = str(raw)
    else:
        s = str(raw).rjust(decimals + 1, "0")
        int_part, frac = s[:-decimals], s[-decimals:].rstrip("0")[:6]
        v = f"{int_part}.{frac}" if frac else int_part
    return f"{v} {symbol}".strip()


def short_addr(addr: str, head: int = 4, tail: int = 4) -> str:
    return f"{addr[:head]}...{addr[-tail:]}" if len(addr) > head + tail + 3 else addr
