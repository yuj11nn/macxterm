# MacXterm

Нативный SSH-клиент для macOS в духе MobaXterm: вкладки терминала, SFTP-панель, пароли в Keychain.

Требования: **macOS 14 или новее, Mac на Apple Silicon (M1 и новее)**. На Intel не запустится.

## Как установить

1. Откройте `MacXterm-<версия>.dmg` и перетащите **MacXterm** на ярлык **Applications**.
2. При первом запуске macOS может написать, что приложение «повреждено» или «не удалось проверить разработчика». Это из‑за того, что сборка не подписана Apple Developer ID. Обойти можно одним из способов:
   - **Через настройки:** попробуйте открыть MacXterm, затем *Системные настройки → Конфиденциальность и безопасность*, внизу «MacXterm заблокировано…» → **Всё равно открыть**, подтвердите паролем.
   - **Через Терминал** (снимает карантин со скачанного файла):
     ```bash
     xattr -dr com.apple.quarantine /Applications/MacXterm.app
     ```
   Это нужно сделать один раз.
3. При первом подключении с сохранённым паролем macOS спросит доступ к связке ключей — нажмите **«Разрешить всегда»**.

## Сборка

Нужны только Command Line Tools (`xcode-select --install`), Xcode не нужен.

```bash
Scripts/build-app.sh --run
```

- `Scripts/make-dev-cert.sh` — один раз создать локальный сертификат «MacXterm Dev»; затем `Scripts/build-app.sh --dev-cert`. Со стабильной подписью Keychain не спрашивает доступ после каждой пересборки. Помогает только на машине разработчика: на другом Mac этот сертификат ничем не лучше ad-hoc.
- `Scripts/make-dmg.sh [--dev-cert]` — собрать `build/MacXterm-<версия>.dmg`.

### Распространение без предупреждений Gatekeeper

Нужен Apple Developer ID ($99/год). Один раз сохраните учётные данные для нотаризации (пароль — app-specific с appleid.apple.com):

```bash
xcrun notarytool store-credentials macxterm --apple-id you@example.com --team-id TEAMID
```

Затем:

```bash
SIGN_ID="Developer ID Application: Имя (TEAMID)" NOTARY_PROFILE=macxterm Scripts/make-dmg.sh
```

Скрипт подпишет приложение с hardened runtime и secure timestamp, подпишет DMG, отправит его на нотаризацию и прикрепит тикет (`stapler`).
