# Premier Router for OpenWrt

Premier Router — пакетный продуктовый слой поверх OpenWrt: интерфейс LuCI,
управление VPN и подключением, безопасные обновления, первичная настройка и
профили сборки образов. Публичный stable 0.7.11 поставляется в виде пакетов.

> **English summary:** Premier Router is a package-first OpenWrt product layer
> for VPN, connectivity, signed transactional updates, onboarding, and
> support-safe diagnostics. Stable 0.7.11 is a package-only release for
> existing OpenWrt 24.10.5 x86/64.

## Обзор

Репозиторий остаётся публичным источником Router UI, OpenWrt-пакетов, профилей
образов и проверяемой логики обновления. Сопутствующее приложение Factory
поддерживается отдельно как закрытый операторский инструмент: оно выбирает и
проверяет подписанный релиз, фиксирует точный provisioning-контекст устройства
и работает по независимому от Router UI циклу версий.

## Статус проекта

| Контур | Текущий статус |
| --- | --- |
| Опубликованный stable | [`Router UI 0.7.11`](https://github.com/tdk4-dev/owrt-router-scripts/releases/tag/vpn-panel-v0.7.11) / `0.7.11-1` — подписанные пакеты для OpenWrt 24.10.5 x86/64. [Установка и миграция](docs/ordinary-user-ipk-installation.md). |
| Предыдущий stable | [`Router UI 0.7.10`](https://github.com/tdk4-dev/owrt-router-scripts/releases/tag/vpn-panel-v0.7.10) — исходная версия для перехода на пакетный релиз. |
| Router UI 0.8.0 | Активная разработка на фундаменте 0.7.11. RU/EN, post-update onboarding и Support & Feedback относятся к development, а не к текущему stable. |
| Xiaomi AX3000T / RD23 | Профили stock и ubootmod разделены; доступны source/static и VM-связанные проверки. Физическая прошивка, загрузка и Factory-canary ещё не подтверждены. |
| Factory companion | Отдельный закрытый операторский инструмент в состоянии private RC: каталог релизов и симулятор проверены, реальный XMiR отключён, физическая квалификация RD23 ожидается. |

## Основные возможности

### Панели и пользовательские сценарии

Перечень описывает текущую package-first линию; поверхности, доступные только
в 0.8 development, помечены отдельно.

- 🧭 **Status → Overview** — краткая карточка Xray и transparent routing,
  выбранный VPN-профиль, endpoint, server IP и результат последней проверки
  соединения.
- 🔐 **Network → VPN Panel** — включение VPN, VLESS Reality-профили и
  subscriptions, проверка доступности серверов, автоматическое переключение,
  direct-routing для доменов/IP и VPN bypass для отдельных устройств.
- 🌐 **Network → Tailscale** — подключение к Tailscale или Headscale,
  start/stop/restart/logout, список tailnet-устройств, direct/DERP path и
  Tailscale ping. Preauth key передаётся сервису и не сохраняется панелью.
- 🛡️ **Network → AdGuardHome** — состояние DNS-фильтрации, количество фильтров,
  переход в AdGuardHome и контролируемая установка после storage preflight.
  Для RD23 установка скрыта и запрещена политикой hardware profile.
- 🔄 **Update** — установленная сборка, проверка релиза и changelog,
  storage preflight, backup, подписанное package-first обновление, журнал
  транзакции, recovery и точный rollback; автоматический stable-канал
  опционален и выключен по умолчанию.
- ♻️ **System → Reset** — только для совместимого `factory-image`: явное
  подтверждение, очистка writable-конфигурации и перезагрузка обратно в
  first-boot setup.
- ⚙️ **Premier Router → Settings** — выбор русского или английского языка
  интерфейса (**0.8 development**).
- ✨ **System → What’s New** — post-update onboarding с обзором изменений
  после релевантного обновления (**0.8 development**).
- 🧰 **System → Router Setup** — вход в опциональный setup для
  `vanilla-openwrt-panels` и указатель на reset/re-run для factory image
  (**0.8 development**).
- 💬 **System → Support & Feedback** — тип и категория обращения, preview
  allowlisted diagnostics и локальный очищенный JSON-export; автоматическая
  отправка пока недоступна (**0.8 development, phase 1**).
- 🚀 **First-boot setup** — отдельный image workflow для hostname/root account,
  LAN и Wi-Fi, VPN, опционального AdGuardHome и Tailscale/Headscale с review
  перед применением.
- 📦 **Owner preparation** — отдельная pre-handoff панель для health checks,
  customer policy, проверенного backup и seal; после seal повторное открытие
  требует доверенного SSH или local console.

### Доступность по release-каналам

- **Stable 0.7.11** — интерфейс Premier Router в LuCI, управление VPN и
  Tailscale/Headscale, подписанные обновления и точный откат. Проверены чистая
  установка пакетов, миграция с 0.7.10, обновление и восстановление после
  перезагрузки. [Результаты security remediation](docs/router-ui-0.7.11-security.md).
- **0.8 development** — локализация RU/EN, post-update onboarding и
  Support & Feedback.
- **Image / Factory** — отдельные сценарии first-boot setup и подготовки
  устройства владельцем. Для них требуется отдельная квалификация.

## Канонические пакеты

Package-first поставка состоит из трёх независимо учитываемых IPK:

- `premier-router-core` — backend-команды, VPN-конфигурация, metadata,
  protocol-2 updater, транзакции, recovery и точный rollback;
- `luci-app-premier-router` — LuCI-страницы Premier Router, VPN, Tailscale,
  Update, RPC ACL и статические UI-ресурсы; Support & Feedback относится к 0.8 development;
- `premier-router-setup` — опциональный first-boot wizard и owner-preparation
  поверхности. Пакет не требуется для core или LuCI на существующем OpenWrt.

Образы собираются из этих же IPK. Образ и ручная установка не должны содержать
разные копии продуктовых файлов.

## Режимы установки

| Режим | Состав и поведение | Уровень поддержки |
| --- | --- | --- |
| `factory-image` | Core + LuCI + setup и metadata образа. Применяет документированные сетевые defaults только в image-first сценарии. | Полный workflow после квалификации конкретного образа и железа; RD23 пока не квалифицирован физически. |
| `vanilla-openwrt-panels` | Core + LuCI; setup опционален. Существующие LAN/WAN, firewall и Wi-Fi сохраняются. | Пакетный релиз 0.7.11 квалифицирован для OpenWrt 24.10.5 x86/64. |
| `headless-core` | Только core, без web-панели и first-boot wizard. | Отдельный advanced/operator путь, вне квалификации stable 0.7.11. |

Установка `premier-router-setup` в `vanilla-openwrt-panels` не должна
перехватывать сеть: мастер остаётся опциональным и может быть пропущен.

## Установка на существующий OpenWrt

Пакетный релиз 0.7.11 предназначен для установки поверх существующего
OpenWrt. Целевой профиль проверки — OpenWrt 24.10.5 x86/64. Установка идёт
из подписанного пакета артефактов. Для 0.7.10 используется отдельно
аутентифицированный rescue-скрипт, а зависимости OpenWrt устанавливаются
до открытия транзакции. Во время обновления и отката транзакция меняет только
три пакета Premier Router и защищённое состояние приложения.

[Инструкция по установке и восстановлению](docs/ordinary-user-ipk-installation.md).

## Образы и оборудование

Профили сборки образов. Stable 0.7.11 распространяется только в виде пакетов.

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

Для 0.7.11 используется ручная установка из релиза с тегом
`vpn-panel-v0.7.11`. Подписанный `stable-channel.json` доступен под этим тегом.
GitHub Latest и автоматическое обнаружение остаются на прежнем канале.

Release discovery не равен доверию. Установка должна проверить публичным
release-ключом подписанные contract/manifest, согласованность версии и канала,
хеши канонических пакетов и образа, locked-feed identity и hardware target.
Draft Release и голый Git tag не являются устанавливаемым релизом. RC никогда
не подменяет stable по умолчанию и не устанавливается автоматически.

Публичный ключ проверки хранится в
[`release/keys/production-2026-07.pub`](release/keys/production-2026-07.pub).
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

При перезапуске LuCI во время обновления сессия может истечь: войдите снова
и проверьте фактический статус перед повторной установкой. Исправленный Update
view сохраняет действие входа и показывает «Reboot required», пока обновление
не подтверждено после перезагрузки. Исправление входит в stable 0.7.11.

## Короткий roadmap

1. Физический RD23 и Factory canary.
2. Завершение backend Support & Feedback и polish onboarding в 0.8.
3. Проверка и публикация 0.8 после release gates.
4. Позднее opt-in развитие Premier Edge.

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
