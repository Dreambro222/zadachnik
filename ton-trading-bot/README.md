# TON Trading Bot

Телеграм-бот для торговли токенами на сети TON: покупка/продажа через STON.fi или DeDust, авто-исполнение Stop-Loss и Take-Profit прямо в чейн.

## Возможности

- **Покупка/продажа** jetton-токенов за TON через DEX (STON.fi или DeDust)
- **Stop-Loss** — продаёт jetton, когда цена в TON падает ниже заданной
- **Take-Profit** — продаёт jetton, когда цена в TON поднимается выше заданной
- **Управление кошельками** через бота: добавить, удалить, посмотреть баланс
- **Шифрование приватных ключей** локально: мнемоник шифруется паролем (PBKDF2-HMAC-SHA256 → Fernet/AES), пароль не хранится на диске
- **Allowlist по Telegram user_id** — посторонние не пройдут middleware

## Безопасность

- Мнемоник присылается боту в личное сообщение и **сразу удаляется** из чата (если у бота есть права на удаление). Хранится только в зашифрованном виде в SQLite.
- Шифрование: PBKDF2-HMAC-SHA256 (480k итераций) → 32-байтовый Fernet-ключ. Соль уникальная на каждый кошелёк + общая `MASTER_SALT` из `.env`. Если потерять `MASTER_SALT` — все ключи становятся нечитаемыми.
- Пароль кешируется в RAM на 15 минут с момента последней операции (`/lock` сбрасывает мгновенно).
- Watcher SL/TP исполняет ордер **только если сессия разлочена**. Если триггер сработал, а сессия залочена, бот пришлёт уведомление и попросит `/unlock`.
- В аллоулист `ALLOWED_USER_IDS` запиши только свой Telegram ID. Остальные обращения молча игнорируются.
- **Это самохостинг.** Запускай только на своей машине. Не выкладывай `.env`, `data/bot.db`, `MASTER_SALT` в публичные репозитории.

## Архитектура

```
bot/
├── main.py                   # Точка входа: aiogram polling + watcher
├── config.py                 # Настройки из .env (pydantic-settings)
├── middlewares.py            # AllowlistMiddleware
├── handlers/                 # Telegram-команды
│   ├── start.py              # /start, /help, главное меню
│   ├── wallet.py             # /addwallet, /balance, /unlock, /lock
│   ├── trade.py              # /buy, /sell (FSM)
│   ├── orders.py             # /neworder, /orders, /cancelorder
│   └── settings.py           # /settings
├── states/flows.py           # FSM: AddWallet, Unlock, Buy, Sell, CreateOrder
├── keyboards/inline.py       # Inline-клавиатуры
├── services/
│   ├── crypto.py             # PBKDF2 + Fernet шифрование секретов
│   ├── wallet_unlock.py      # In-memory кеш паролей (TTL 15 мин)
│   ├── ton_client.py         # tonutils: восстановление кошелька, балансы
│   ├── dex.py                # Унифицированный DEX-интерфейс над STON.fi/DeDust
│   ├── trade_executor.py     # Декрипт + свап + лог trade
│   └── orders_engine.py      # Фоновый воркер SL/TP
├── db/
│   ├── schema.sql            # Схема SQLite
│   └── repository.py         # CRUD: users, wallets, orders, trades
└── utils/format.py           # Хелперы форматирования
tests/
└── test_crypto.py            # Smoke-тесты шифрования
```

## Команды бота

| Команда | Действие |
|---|---|
| `/start`, `/help` | Главное меню |
| `/addwallet` | Добавить кошелёк (мнемоник → пароль → шифр) |
| `/wallet` | Список кошельков |
| `/removewallet <id>` | Удалить кошелёк |
| `/balance` | Балансы TON по всем кошелькам |
| `/unlock` | Ввести пароль (разлочить на 15 минут) |
| `/lock` | Заблокировать сессию |
| `/buy` | Купить jetton за TON |
| `/sell` | Продать jetton за TON |
| `/neworder` | Создать Stop-Loss или Take-Profit |
| `/orders` | Список ордеров |
| `/cancelorder <id>` | Отменить ордер |
| `/settings` | Текущие настройки |

## Логика SL / TP

Watcher `bot/services/orders_engine.py` запускается фоновой задачей в `main.py` и каждые `ORDER_POLL_INTERVAL` секунд:

1. Берёт все ордера со статусом `active`.
2. Для каждого запрашивает у выбранного DEX котировку «сколько jetton дают за 1 TON» и инвертирует в спот-цену TON/jetton.
3. Условие срабатывания:
   - `stop_loss`/sell: `price <= trigger_price`
   - `take_profit`/sell: `price >= trigger_price`
4. При срабатывании достаёт пароль из in-memory кеша → расшифровывает мнемоник → подписывает свап → отправляет в чейн через STON.fi/DeDust.
5. Статус ордера переходит `triggered → filled` (или `failed` с `last_error`). Пользователь получает уведомление с tx-хешем.
6. Если сессия залочена — ордер остаётся `active`, бот шлёт напоминание сделать `/unlock`.

## Установка

Нужен Python 3.11+.

```bash
cd ton-trading-bot
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# отредактируй .env: BOT_TOKEN, ALLOWED_USER_IDS, MASTER_SALT
```

`MASTER_SALT` сгенерируй один раз и больше не меняй:

```bash
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

## Запуск

```bash
python -m bot.main
```

В первом сообщении боту: `/start` → `/addwallet` → пришли 24-словный мнемоник → задай пароль. Можно сразу `/buy` или `/neworder`.

## Тесты

```bash
pip install pytest
python -m pytest tests/
```

## Что не делает бот (намеренно)

- Не хранит пароль на диске. Если перезапустить процесс — нужно `/unlock` заново.
- Не торгует чужими токенами без вашего пароля.
- Не работает с парами jetton↔jetton: только jetton↔TON. Для перехода между двумя jetton — два свапа.
- Не управляет лимитными ордерами (только SL/TP по триггеру цены).
- Не следит за газом: убедись, что на кошельке есть свободный TON для комиссий (≥ 0.2 TON для свапа).

## Дисклеймер

Софт предоставляется «как есть». Торговля криптой связана с риском полной потери средств. Перед использованием на mainnet протестируй на testnet (`TON_NETWORK=testnet`).
