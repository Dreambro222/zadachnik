"""
In-memory unlock cache. Maps user_id -> password (string), valid for TTL seconds.

The password itself is never written to disk. It is required to decrypt the
mnemonic and sign transactions. After TTL it expires and the user must re-enter.
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Optional

UNLOCK_TTL = 15 * 60  # 15 minutes


@dataclass
class _Entry:
    password: str
    expires_at: float


class UnlockCache:
    def __init__(self, ttl: int = UNLOCK_TTL):
        self._ttl = ttl
        self._cache: dict[int, _Entry] = {}

    def unlock(self, user_id: int, password: str) -> None:
        self._cache[user_id] = _Entry(password, time.monotonic() + self._ttl)

    def get(self, user_id: int) -> Optional[str]:
        e = self._cache.get(user_id)
        if not e:
            return None
        if time.monotonic() > e.expires_at:
            self._cache.pop(user_id, None)
            return None
        # sliding window: refresh on each access
        e.expires_at = time.monotonic() + self._ttl
        return e.password

    def lock(self, user_id: int) -> None:
        self._cache.pop(user_id, None)


unlock_cache = UnlockCache()
