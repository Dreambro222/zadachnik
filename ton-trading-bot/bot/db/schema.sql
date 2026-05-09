CREATE TABLE IF NOT EXISTS users (
    user_id      INTEGER PRIMARY KEY,
    created_at   INTEGER NOT NULL,
    default_slippage REAL NOT NULL DEFAULT 1.0,
    default_dex  TEXT NOT NULL DEFAULT 'stonfi'
);

CREATE TABLE IF NOT EXISTS wallets (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id      INTEGER NOT NULL,
    label        TEXT NOT NULL,
    address      TEXT NOT NULL,
    user_salt    BLOB NOT NULL,
    ciphertext   BLOB NOT NULL,         -- encrypted mnemonic (24 words space-separated) or hex priv key
    secret_kind  TEXT NOT NULL,          -- 'mnemonic' | 'private_key'
    is_active    INTEGER NOT NULL DEFAULT 1,
    created_at   INTEGER NOT NULL,
    UNIQUE(user_id, address),
    FOREIGN KEY (user_id) REFERENCES users(user_id)
);

CREATE INDEX IF NOT EXISTS idx_wallets_user ON wallets(user_id);

CREATE TABLE IF NOT EXISTS orders (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id      INTEGER NOT NULL,
    wallet_id    INTEGER NOT NULL,
    kind         TEXT NOT NULL,                  -- 'stop_loss' | 'take_profit'
    side         TEXT NOT NULL,                  -- 'sell' | 'buy'
    jetton_master TEXT NOT NULL,                 -- master address of the token
    jetton_symbol TEXT,
    -- Trigger condition: price of jetton in TON.
    -- For stop_loss/sell:  trigger when price <= trigger_price
    -- For take_profit/sell: trigger when price >= trigger_price
    trigger_price REAL NOT NULL,
    -- Amount in jetton smallest units (string to avoid precision loss)
    amount_units TEXT NOT NULL,
    slippage_pct REAL NOT NULL DEFAULT 1.0,
    dex          TEXT NOT NULL DEFAULT 'stonfi',
    status       TEXT NOT NULL DEFAULT 'active', -- 'active' | 'triggered' | 'filled' | 'failed' | 'cancelled'
    last_error   TEXT,
    tx_hash      TEXT,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(user_id),
    FOREIGN KEY (wallet_id) REFERENCES wallets(id)
);

CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_user ON orders(user_id);

CREATE TABLE IF NOT EXISTS trades (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id      INTEGER NOT NULL,
    wallet_id    INTEGER NOT NULL,
    order_id     INTEGER,
    side         TEXT NOT NULL,
    jetton_master TEXT NOT NULL,
    amount_in    TEXT NOT NULL,
    amount_out_estimate TEXT,
    dex          TEXT NOT NULL,
    tx_hash      TEXT,
    status       TEXT NOT NULL,
    created_at   INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(user_id),
    FOREIGN KEY (wallet_id) REFERENCES wallets(id),
    FOREIGN KEY (order_id) REFERENCES orders(id)
);
