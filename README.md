# Premier Router for OpenWrt

Premier Router — пакетный продуктовый слой поверх OpenWrt: интерфейс LuCI,
управление VPN и подключением, безопасные обновления, первичная настройка и
проверяемые образы для поддерживаемых профилей. Это уже не просто набор
скриптов установки.

> **English summary:** Premier Router is a package-first OpenWrt product layer
> for VPN, connectivity, signed transactional updates, onboarding, and
> support-safe diagnostics. The public stable, limited RC, and active
> development states are intentionally documented separately.

## Обзор

Репозиторий остаётся публичным источником Router UI, OpenWrt-пакетов, профилей
образов и проверяемой логики обновления. Сопутствующее приложение Factory
поддерживается отдельно как закрытый операторский инструмент: оно выбирает и
проверяет подписанный релиз, фиксирует точный provisioning-контекст устройства
и работает по независимому от Router UI циклу версий.

## Статус проекта

| Контур | Текущий статус |
| --- | --- |
| Опубликованный stable | [`Router UI 0.7.10`](https://github.com/tdk4-dev/owrt-router-scripts/releases/tag/vpn-panel-v0.7.10) — текущий публичный стабильный релиз. Он предшествует package-first переходу 0.7.11. |
| Router UI 0.7.11 RC | Package-first RC локально проверен на уровне пакетов, protocol 2, обновления, перезагрузки и точного отката. Публичный stable 0.7.11 ещё не опубликован; locked-image и аппаратная квалификация описываются отдельно и не считаются завершёнными. |
| Router UI 0.8.0 | Активная разработка на фундаменте 0.7.11. RU/EN, post-update onboarding и Support & Feedback относятся к development, а не к текущему stable. |
| Xiaomi AX3000T / RD23 | Профили stock и ubootmod разделены; доступны source/static и VM-связанные проверки. Физическая прошивка, загрузка и Factory-canary ещё не подтверждены. |
| Factory companion | Отдельный закрытый операторский инструмент в состоянии private RC: каталог релизов и симулятор проверены, реальный XMiR отключён, физическая квалификация RD23 ожидается. |

RC 0.7.11 не является опубликованным stable, а 0.8 не является релизом.
Ни один из этих каналов не устанавливается на клиентский роутер автоматически.

## Основные возможности

Метки ниже показывают, где функция существует или проверяется, и не превращают
development-код в обещание stable-релиза.

- **Stable 0.7.10:** интерфейс Premier Router в LuCI; управление профилями
  VPN/VLESS Reality и direct-routing; поверхности статуса Tailscale/Headscale.
- **0.7.11 RC:** канонические package-first IPK, подписанные release manifests,
  updater protocol 2, журнал транзакции, восстановление после перезагрузки и
  точный rollback без глобального обновления OpenWrt.
- **0.7.11 RC / image workflow:** first-boot setup, owner preparation и
  installation/support metadata. Реальное RD23-прохождение остаётся отдельным
  аппаратным gate.
- **0.8 development:** русско- и англоязычный UI там, где локализация уже
  реализована; framework post-update onboarding; Support & Feedback phase 1 с
  allowlist, предварительным просмотром и очищенным экспортом диагностики.
- **0.7.11 RC и новее:** поверхность совместимости с подписанным Factory
  release contract. Factory обязан проверить контракт, manifest, ключ, хеши и
  точный hardware variant; одних GitHub-метаданных недостаточно.

## Канонические пакеты

Package-first поставка состоит из трёх независимо учитываемых IPK:

- `premier-router-core` — backend-команды, VPN-конфигурация, metadata,
  protocol-2 updater, транзакции, recovery и точный rollback;
- `luci-app-premier-router` — LuCI-страницы Premier Router, VPN, Tailscale,
  Update и Support & Feedback, RPC ACL и статические UI-ресурсы;
- `premier-router-setup` — опциональный first-boot wizard и owner-preparation
  поверхности. Пакет не требуется для core или LuCI на существующем OpenWrt.

Образы собираются из этих же IPK. Образ и ручная установка не должны содержать
разные копии продуктовых файлов.

## Режимы установки

| Режим | Состав и поведение | Уровень поддержки |
| --- | --- | --- |
| `factory-image` | Core + LuCI + setup и metadata образа. Применяет документированные сетевые defaults только в image-first сценарии. | Полный workflow после квалификации конкретного образа и железа; RD23 пока не квалифицирован физически. |
| `vanilla-openwrt-panels` | Core + LuCI; setup опционален. Существующие LAN/WAN, firewall и Wi-Fi сохраняются. | Стандартный package-first путь для существующего OpenWrt. |
| `headless-core` | Только core, без web-панели и first-boot wizard. | Ограниченный advanced/operator путь. |

Установка `premier-router-setup` в `vanilla-openwrt-panels` не должна
перехватывать сеть: мастер остаётся опциональным и может быть пропущен.

## Установка на существующий OpenWrt

Существующий OpenWrt можно обновить проверенными IPK или через подписанный
package feed без перепрошивки. Текущий публичный stable 0.7.10 использует свой
опубликованный release workflow; package-first команды ниже относятся только к
явно выданному **limited 0.7.11 RC bundle**, а не к `main` и не к 0.8
development.

На доверенной рабочей станции в неизменяемом каталоге одного RC сначала
проверьте подпись manifest штатным RC-инсталлятором и затем все SHA-256:

```sh
sha256sum -c SHA256SUMS
```

OpenWrt/Dropbear не гарантирует SFTP. Передать три проверенных IPK можно через
SSH и tar-stream:

```sh
tar -cf - \
  premier-router-core_0.7.11-1_all.ipk \
  luci-app-premier-router_0.7.11-1_all.ipk \
  premier-router-setup_0.7.11-1_all.ipk | \
ssh root@ROUTER 'umask 077; mkdir -p /tmp/premier-router-0.7.11-rc; tar -xf - -C /tmp/premier-router-0.7.11-rc'
```

Для стандартного режима с панелями установите core и LuCI; setup добавляйте
только при необходимости:

```sh
ssh root@ROUTER 'opkg install \
  /tmp/premier-router-0.7.11-rc/premier-router-core_0.7.11-1_all.ipk \
  /tmp/premier-router-0.7.11-rc/luci-app-premier-router_0.7.11-1_all.ipk'
```

```sh
ssh root@ROUTER 'opkg install \
  /tmp/premier-router-0.7.11-rc/premier-router-setup_0.7.11-1_all.ipk'
```

Если оператор RC предоставляет подписанный feed, после установки его публичного
ключа и точной feed-конфигурации из release notes используются только
`opkg update` и установка пакетов Premier Router. **Не выполняйте глобальный
`opkg upgrade`**: он смешивает независимые обновления OpenWrt и продукта и
лишает транзакцию проверяемой границы.

Raw-branch installers не являются рекомендуемым release-путём. Не загружайте и
не запускайте установщик непосредственно из mutable-ветки.

## Образы и оборудование

Поддерживаемые build targets:

- **x86/64** — EFI/BIOS образы для router-PC и изолированной VM. В x86-профиле
  AdGuardHome доступен как опциональный компонент при прохождении проверки
  постоянного хранилища;
- **Xiaomi AX3000T / RD23 stock** — профиль для штатной OpenWrt boot layout;
- **Xiaomi AX3000T / RD23 ubootmod** — другой профиль для устройства, уже
  переведённого на OpenWrt U-Boot layout.

Stock и ubootmod — не взаимозаменяемые имена одного файла. Выбор обязан
совпадать с фактической разметкой загрузчика; ubootmod-образ нельзя прошивать на
stock-устройство без предварительной конверсии по отдельно проверенной
процедуре.

RD23 использует lean profile
[`image/openwrt-rd23-packages.txt`](image/openwrt-rd23-packages.txt) и по
умолчанию **не включает AdGuardHome**: flash зарезервирована под core, LuCI,
Xray и update/support tooling. Все release-образы должны собираться с
зафиксированным OpenWrt feed; сборка против mutable feed не является
воспроизводимой release-квалификацией.

Static-проверка состава и VM-проверка x86 не доказывают загрузку или безопасную
прошивку RD23. До физического stock/ubootmod canary аппаратный статус остаётся
pending.

## Обновления и release-каналы

- **Stable** — опубликованный непререлизный GitHub Release после отдельной
  авторизации и полного gate;
- **RC / pre-release** — явно выбранный тестовый GitHub Pre-release для
  ограниченной проверки;
- **Development** — локальная или веточная сборка, не предназначенная для
  клиентского production-устройства.

0.7.11 — migration bridge к package-first IPK и updater protocol 2. Разработка
0.8 строится поверх этой основы, но остаётся отдельным development-потоком.

Release discovery не равен доверию. Установка должна проверить публичным
release-ключом подписанные contract/manifest, согласованность версии и канала,
хеши канонических пакетов и образа, locked-feed identity и hardware target.
Draft Release и голый Git tag не являются устанавливаемым релизом. RC никогда
не подменяет stable по умолчанию и не устанавливается автоматически.

Публичный ключ проверки хранится в
[`release/keys/router-ui-production.pub`](release/keys/router-ui-production.pub).
Приватного signing key в роутере, release bundle или Factory быть не должно.

## Требования к ресурсам

Текущие измеренные preflight gates для **0.8 development**:

- свободное постоянное хранилище: **1 641 KiB**;
- свободное RAM-backed `/tmp`: **1 105 KiB**.

Это пороги безопасного updater preflight с резервом на транзакцию и rollback,
а не полный размер firmware и не обещание вместимости любого hardware profile.
Перед обновлением оба независимых порога должны быть пройдены.

## Безопасность и приватность

- Release trust основан на подписанных manifests/contracts и публичных ключах,
  а не на имени тега или GitHub Release metadata.
- Приватный release-ключ не хранится на роутере и не требуется Factory для
  проверки.
- Package-first update сохраняет конфигурацию, создаёт snapshot и изменяет
  только проектные пакеты; глобальный `opkg upgrade` запрещён.
- Transaction journal и recovery различают commit, незавершённое обновление и
  exact rollback после перезагрузки.
- Support diagnostics используют allowlist и доступны для preview до экспорта.
  Raw logs, customer secrets, VPN credentials и полные идентификаторы не
  загружаются автоматически.
- Deployment-specific значения должны жить в локальной конфигурации и не
  попадать в Git, release assets или документацию.

## Короткий roadmap

1. Ограниченная дистрибуция 0.7.11 RC.
2. Физический RD23 и Factory canary.
3. Публикация stable 0.7.11 после отдельной авторизации.
4. Завершение backend Support & Feedback и polish onboarding в 0.8.
5. Проверка и публикация 0.8 после release gates.
6. Позднее opt-in развитие Premier Edge.

## Разработка

Актуальные публичные правила и методики на `main`:

- [правила репозитория и release safety](AGENTS.md);
- [development workflow и уровни доказательств](docs/development-workflow.md);
- [методика VM-проверки релизов](docs/vm-release-testing-methodology.md);
- [границы customer/owner policy](docs/customer-owner-policy.md);
- [правила владения footer branding](docs/footer-branding.md);
- [исходники и структура LuCI-панели](luci-vpn-ui/README.md).

При разработке разделяйте source/static, simulated, VM-validated и
hardware-validated результаты. Не помещайте реальные VLESS links, auth keys,
private domains, customer data или локальные адреса устройств в репозиторий.

Публикация тега, GitHub Release или release asset всегда требует отдельной
явной авторизации. Изменение версии или README само по себе такой авторизацией
не является.
