# BACK_TO_USSR v1.0
## Universal Secure Server Router

### RU
Первый стабильный релиз `BACK_TO_USSR` для старых Intel Mac на macOS Big Sur 11.x+.

Этот проект появился из реальной проблемы: старый Mac не тянет современные VPN-клиенты, App Store часто недоступен без VPN, а без VPN нельзя получить нормальный интернет. Получается замкнутый круг.

`BACK_TO_USSR` разрывает этот круг: приложение можно передать офлайн (AirDrop/USB), запустить и сразу подключаться по URL-подпискам.

Что внутри:
- menu-bar приложение (иконка рядом с часами);
- несколько Subscription URL одновременно (без ограничений);
- обновление серверов, объединение и удаление дублей;
- автодозвон: выбранный сервер -> последний успешный -> весь пул;
- fallback `flow on -> flow off`;
- авто-реконнект при потере соединения;
- показ текущего IP и статуса;
- музыкальные оповещения с mute.

Установка:
1. Скачайте `BACK_TO_USSR.app.zip` из релиза.
2. Переместите `BACK_TO_USSR.app` в `/Applications`.
3. Если macOS блокирует запуск:
   ```bash
   xattr -cr /Applications/BACK_TO_USSR.app
   ```
4. Откройте приложение -> `Manage Subscription URLs` -> вставьте URL -> `Refresh Servers` -> `Connect`.

---

### EN
First stable release of `BACK_TO_USSR` for old Intel Macs on macOS Big Sur 11.x+.

This project came from a real-world issue: older Macs often cannot run modern VPN clients, App Store access may be blocked without VPN, and without VPN you cannot restore open internet. A classic lockout loop.

`BACK_TO_USSR` breaks that loop: you can transfer the app offline (AirDrop/USB), launch it, and connect using subscription URLs.

Highlights:
- menu-bar app near macOS clock;
- unlimited subscription URLs;
- refresh, merge and deduplicate server nodes;
- autodial strategy: selected -> last successful -> full pool;
- fallback `flow on -> flow off`;
- auto-reconnect on connection loss;
- status and current IP in menu;
- optional anthem notifications with mute.

Install:
1. Download `BACK_TO_USSR.app.zip` from this release.
2. Move `BACK_TO_USSR.app` to `/Applications`.
3. If macOS blocks startup:
   ```bash
   xattr -cr /Applications/BACK_TO_USSR.app
   ```
4. Open app -> `Manage Subscription URLs` -> paste URL(s) -> `Refresh Servers` -> `Connect`.
