# 3X-UI — одностраничник после установки

Быстрая шпаргалка сразу после развёртывания панели 3X-UI. Главное действие — **убрать
рекламу одной командой**. Патч не трогает клиентов, inbounds и xray.

---

## 1. Убрать рекламу (одна команда)

На сервере с 3X-UI (панель за nginx):

```bash
curl -fsSL https://raw.githubusercontent.com/Anton98567/3x-ui-no-ads/main/3x-ui-no-ads.sh | sudo bash
```

Скрипт сам найдёт панель и base-path, вставит перехват `/sponsors` в nginx и перезагрузит его.
Если авто-определение не сработало — укажите адрес панели явно:

```bash
curl -fsSL https://raw.githubusercontent.com/Anton98567/3x-ui-no-ads/main/3x-ui-no-ads.sh | sudo bash -s -- --url https://<host>/<base-path>/
```

Откройте панель и нажмите **Ctrl+F5** (браузер должен выбросить закэшированную карточку).

---

## 2. Проверить

```bash
# живой эндпоинт (пустой список = рекламы нет)
curl -s https://<host>/<base-path>/sponsors
# ожидаемо: {"success":true,"msg":"","obj":{"contact":"","sponsors":[]}}

# полная проверка патча и целостности служб
curl -fsSL https://raw.githubusercontent.com/Anton98567/3x-ui-no-ads/main/3x-ui-no-ads.sh | sudo bash -s -- verify --url https://<host>/<base-path>/
```

---

## 3. Откатить (реклама вернётся)

```bash
curl -fsSL https://raw.githubusercontent.com/Anton98567/3x-ui-no-ads/main/3x-ui-no-ads.sh | sudo bash -s -- remove
```

---

## 4. Прогнать по всем серверам одной петлёй

```bash
for h in host1 host2 host3; do
  echo "=== $h ==="
  ssh root@$h 'curl -fsSL https://raw.githubusercontent.com/Anton98567/3x-ui-no-ads/main/3x-ui-no-ads.sh | bash'
done
```

---

## 5. Полезные команды патча

| Команда | Что делает |
|---|---|
| `… \| sudo bash` | **снять рекламу** (авто-определение) |
| `… \| sudo bash -s -- status` | показать состояние патча |
| `… \| sudo bash -s -- verify --url https://…/` | проверить результат и службы |
| `… \| sudo bash -s -- remove` | откатить |
| `… \| sudo bash -s -- apply --dry-run` | посмотреть, что изменится, ничего не писая |

---

## Замечания

* **Клиенты не затрагиваются**: меняется только nginx-конфиг эндпоинта `/sponsors`;
  `x-ui.db`, inbounds, клиенты и xray не трогаются.
* Патч **переживает ребуты и `reload nginx`**. Может пропасть, только если конфиг nginx
  пересоздадут целиком (например certbot-скриптом) — тогда повторите `apply`.
* Панель должна быть **за nginx** (стандартная схема). Если открыта напрямую без nginx —
  см. README, раздел «Важные замечания».
* Несколько панелей на одном сервере — прогоните скрипт для каждого base-path
  (`--url https://host/<base-1>/`, затем `<base-2>/`).
