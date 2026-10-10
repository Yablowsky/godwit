# Godwit Modern и Legacy: сборка двух приложений

Это две отдельные ветки, а не два режима одной сборки. Собирать их нужно в
разных каталогах. Нельзя переносить Mobile.xcframework из одной версии в другую.

| Версия | Ветка Godwit | Репозиторий ядра | Зафиксированный commit |
|---|---|---|---|
| Modern | `codex/stabilize-runtime-lifecycle` | `openlibrecommunity/olcrtc` | `189d16c093c4f721376afb5eaa0213d132a11242` |
| Legacy | `codex/stabilize-legacy-runtime` | `Yablowsky/olcrtc-legacy` | `e2c4b1e3d25db933b689c3816dba643ee8a72101` |

## Подготовка на Mac

Нужны полный Xcode, Go и Homebrew (для установки XcodeGen, если его нет).
Скрипты выбирают Go 1.26.3 и проверяют commit ядра. CI использует Xcode 26.3;
Xcode 27 на пользовательском Mac нужно проверить отдельно.

```bash
mkdir -p ~/dev/godwit-editions
cd ~/dev/godwit-editions

git clone --branch codex/stabilize-runtime-lifecycle git@github.com:Yablowsky/godwit.git modern
git clone https://github.com/openlibrecommunity/olcrtc.git modern-core
git -C modern-core checkout --detach 189d16c093c4f721376afb5eaa0213d132a11242
./modern/apple/Scripts/prepare-xcode.sh --olcrtc-root "$PWD/modern-core"

git clone --branch codex/stabilize-legacy-runtime git@github.com:Yablowsky/godwit.git legacy
git clone git@github.com:Yablowsky/olcrtc-legacy.git legacy-core
git -C legacy-core checkout --detach e2c4b1e3d25db933b689c3816dba643ee8a72101
./legacy/apple/Scripts/prepare-xcode.sh --olcrtc-root "$PWD/legacy-core"
```

Каждый скрипт собирает свой framework и генерирует `apple/Godwit.xcodeproj`.
Схема iOS в обоих проектах называется `OlcRTCClient iOS`.

## Идентификаторы и подпись

Предложенные идентификаторы уже записаны в проектах; владелец Apple Developer
аккаунта должен зарегистрировать их или сообщить свои до выпуска профилей.

| Target | Modern | Legacy |
|---|---|---|
| Приложение iOS | `com.egorozh.godwit` | `com.egorozh.godwit.legacy` |
| PacketTunnel | `com.egorozh.godwit.PacketTunnel` | `com.egorozh.godwit.legacy.PacketTunnel` |

В App Store Connect нужны **две** карточки приложений, расширения отдельно не
создаются. Для TestFlight нужны Apple Distribution certificate с private key
и четыре соответствующих App Store Connect provisioning profile. Оба target
каждой версии требуют `com.apple.developer.networking.networkextension` со
значением `packet-tunnel-provider`. Team должен совпадать у приложения и расширения.

Владелец аккаунта может использовать automatic signing. При ручной подписи
выберите отдельный профиль в Signing & Capabilities каждого из двух target.
Не передавайте сертификаты, private key и пароли в Git.

Если меняете Bundle ID, правьте `apple/project.yml`, затем перегенерируйте проект.
ID расширения должен равняться ID приложения + `.PacketTunnel`. Изменение только
через Xcode будет потеряно при следующем запуске XcodeGen.

В Xcode выберите устройство назначения для iOS, затем Product → Archive.
В Organizer используйте Distribute App → App Store Connect. Номер сборки
`CURRENT_PROJECT_VERSION` увеличивайте при каждой следующей загрузке для той же
версии приложения. У каждой ветки собственная последовательность номеров.
Приглашённый пользователь App Store Connect с ролью Developer может загружать
подписанную IPA через Transporter под своим Apple Account.

## Что проверять

Legacy использует неизменённое старое ядро и предназначен для старого рабочего
сервера. Modern требует совместимого нового сервера; это не взаимозаменяемые
клиенты. На iOS legacy mobile API поддерживает только VP8 и datachannel;
неподдерживаемый транспорт отклоняется явно. macOS CLI сохраняет SEI/video.
Существующие параметры профилей не переписываются. Новые VP8-профили Legacy
сохраняют прежние defaults Godwit: 60 FPS / batch 64.

В Legacy глобальные Start/Stop/WaitReady сериализованы с проверкой владельца
сессии. Повторный Stop присоединяется к уже начатой остановке; запоздалый Stop
старой сессии не может остановить новую. После 5 секунд ожидания зависшего Stop
управление возвращается приложению, но ядро остаётся занятым до реального
завершения. Исправить внутреннее зависание Go таким ограничением нельзя.
Остановка VPN по-прежнему подтверждается системным статусом Network Extension.

Обе версии могут быть установлены одновременно, но системный VPN тестируйте
по очереди. У локальных прокси при одновременном запуске должны быть разные порты.
Проверки на устройстве: старт/стоп, отмена подключения, повторный старт,
перезапуск UI при активном VPN, Wi-Fi/LTE, авиарежим, переход к другому VPN.
Успешная unsigned CI-сборка не заменяет эти испытания и не проверяет подпись.

Фоновая работа local proxy на iOS имеет прежние ограничения обычного приложения;
режим нельзя считать гарантированным always-on.
