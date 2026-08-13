# Premier Router — Scope of Work: `0.7.11` → `0.8.0`

**Статус:** active / normative  
**Дата фиксации:** 2026-07-24  
**Применяется к:** Router UI, OpenWrt images/IPKs, updater, Factory, setup flow, support bundle и release tooling  
**Текущий hardware-контекст:** отдельный DNS RD23 заказан как лабораторный стенд; три устройства из китайской партии ожидаются позднее

---

## 1. Назначение документа

Этот файл фиксирует обязательный объём ближайших релизов и защищает release train от расширения scope без доказуемого роста качества.

Документ является нормативным для Codex и разработчиков:

1. Перед изменением необходимо определить целевой релиз и конкретный acceptance criterion, который изменение закрывает.
2. Если изменение не закрывает blocker, regression или явно перечисленный критерий текущего релиза, оно переносится в `0.8.1+`.
3. Запрещено изменять этот файл как побочную часть реализации. Изменение scope допускается только отдельным осознанным решением владельца проекта.
4. Нельзя переименовывать, патчить или повторно публиковать существующие артефакты под тем же version/tag.
5. Любая новая сборка получает новую идентичность и собственный комплект evidence.

Нормативные слова:

- **MUST** — обязательно для выхода релиза;
- **MUST NOT** — запрещено в рамках релиза;
- **SHOULD** — желательно, но не является blocker без отдельного решения;
- **MAY** — допустимо, но не обязательно;
- **DEFERRED** — намеренно вынесено из текущего release train.

---

## 2. Зафиксированный release train

| Этап | Назначение | Новые функции |
|---|---|---|
| Current `0.7.11-rc.*` | Проверка переходного trust/update bridge | Запрещены |
| `0.7.11` stable | Безопасный переход legacy-установок на protocol 2 и будущий `0.8.x` | Запрещены |
| `0.8.0-dev2` | Security, updater, Factory и reproducibility hardening | Запрещены |
| `0.8.0-dev3` | Локализация и исправление уже заявленного UX | Только исправления заявленного поведения |
| Дополнительный `0.8.0-devN` | Только устранение дефектов в зафиксированном scope | Запрещены |
| `0.8.0-rc.1` | Полная VM- и hardware-валидация замороженного продукта | Запрещены |
| `0.8.0-rc.N` | Только blocker fixes найденные в RC | Запрещены |
| `0.8.0` stable | Публичный production release проверенных вариантов | Запрещены |
| `0.8.1+` | Отложенные улучшения и расширение продукта | Разрешены отдельным scope |

### Статус `0.8.0-dev1`

`0.8.0-dev1` и артефакты от `e20d738`:

- MUST оставаться историческим defect-reproduction snapshot;
- MUST быть помечены `test-only`;
- MUST NOT использоваться как RC, Factory production input или release candidate;
- MUST NOT переименовываться в более позднюю версию;
- MAY использоваться только для воспроизведения уже известных дефектов и сравнения поведения.

---

## 3. Глобальные release-инварианты

Эти требования применяются ко всем релизам ниже.

### 3.1. Идентичность и неизменяемость

- Один tag/version соответствует одному неизменяемому набору bytes.
- Изменение source, feed lock, signing key, build/staging script, Factory contract или metadata создаёт новую сборку.
- Повторная загрузка изменённых assets под существующим tag запрещена.
- Evidence от одной сборки нельзя переносить на другую, даже если diff кажется незначительным.

### 3.2. Чистая сборка

Release staging MUST отказываться при:

- modified tracked files;
- staged, но не закоммиченных файлах;
- влияющих на сборку untracked files;
- неизвестном source commit;
- несовпадении ожидаемого staging/build script commit;
- незалоченном feed или toolchain input;
- отсутствии обязательной provenance metadata.

Provenance MUST включать как минимум:

- source commit;
- branch или release ref;
- `source_dirty`;
- build/staging script commit;
- ImageBuilder/toolchain identity;
- feed lock identity;
- input IPK hashes;
- output image/IPK hashes;
- Factory contract digest;
- signing key ID без приватного материала.

### 3.3. Воспроизводимость

- Финальные IPK и images MUST быть собраны дважды из чистых checkout/worktree.
- Результаты MUST сравниваться побайтово либо иметь заранее документированное и проверяемое исключение для недетерминированной metadata.
- Непредусмотренный hash drift является release blocker.

### 3.4. Security и privacy

- Неаутентифицированный LAN-клиент не должен изменять пароль, сеть, setup state, language после setup completion или запускать mutating helper commands.
- Read-only LuCI user не должен иметь технической возможности вызвать mutating API/helper command.
- Support diagnostics не должны содержать persistent router/client identifier.
- Любой токен intentional setup reopen должен быть короткоживущим, одноразовым и храниться только в volatile storage.

### 3.5. Варианты продукта валидируются независимо

`x86`, `RD23 stock` и `RD23 ubootmod` считаются отдельными release variants.

- Variant без полного требуемого evidence MUST NOT публиковаться.
- Variant нельзя добавить к уже выпущенному immutable release задним числом.
- Неготовый variant переносится в следующий релиз.

### 3.6. Правило сокращения scope

При выборе между расширением реализации и безопасным отключением необязательной функции текущий release train предпочитает безопасное отключение.

---

# 4. Release `0.7.11`

## 4.1. Цель

`0.7.11` — переходный trust/update bridge для существующих установок. Его задача — безопасно перевести legacy routers на protocol 2, подписанные manifests, transactional package update и точный rollback перед переходом на `0.8.x`.

`0.7.11` не является продуктовым feature release.

## 4.2. Обязательный scope

### Trust root и подписи

- [ ] Определён production signing key и стабильный key ID.
- [ ] Private key отсутствует в репозитории, build artifacts и обычном developer environment.
- [ ] Public key встроен в точные release artifacts.
- [ ] Test/dev signatures отвергаются production validator.
- [ ] Задокументирован emergency key rotation/revocation path.

### Updater bridge

- [ ] Protocol 2 manifest verification работает на реальных release artifacts.
- [ ] Transactional package update сохраняет pre-update state.
- [ ] Commit и exact rollback работают после reboot.
- [ ] Неизвестные, dev и неподдерживаемые версии fail closed до мутации.
- [ ] Version parser поддерживает будущую явную пару `devN` ↔ `dev.N` без неоднозначности.
- [ ] Ошибки проверки подписи, checksum, compatibility и storage не маскируются как success.

### Locked baseline artifacts

- [ ] Собраны locked-feed `0.7.11` IPKs.
- [ ] Собраны точные release images для заявленных variants.
- [ ] Для каждого публикуемого variant существует schema-2 Factory contract.
- [ ] Для каждого contract существует detached signature и image-package-manifest digest.
- [ ] Factory import выполняется реальным current Factory `0.2.0-rc.1+`, а не только fixture tests.

### Regression/security check

- [ ] Проверено отсутствие unauthenticated setup reopen/password/network mutation.
- [ ] Проверено отсутствие mutating access у read-only LuCI user.
- [ ] Support bundle не содержит persistent client/router identifiers.
- [ ] Vanilla core+LuCI остаётся работоспособным без опциональных пакетов.

## 4.3. Обязательная VM-матрица

До stable должны пройти на точных кандидатных bytes:

- [ ] Exact published `0.7.9` → `0.7.11` через поддерживаемый штатный путь.
- [ ] Exact published `0.7.10` → `0.7.11` через поддерживаемый штатный путь.
- [ ] Каждый другой явно поддерживаемый legacy baseline → `0.7.11`.
- [ ] Неподдерживаемая/unknown/dev/RC версия → отказ до мутации.
- [ ] Повторная установка `0.7.11` → идемпотентное безопасное поведение.
- [ ] Успешное обновление → commit → reboot → сохранение состояния.
- [ ] Успешное обновление → exact rollback → восстановление пакетов и конфигурации.
- [ ] Ошибка download/checksum/signature/compatibility/storage → сохранение исходного состояния.
- [ ] Factory schema-2 import → provisioning → first boot → setup → handoff.
- [ ] Инъекция недостаточного persistent space и `/tmp` → ранний понятный отказ.

## 4.4. Hardware-gate для `0.7.11`

DNS RD23 используется как первый destructive hardware-in-the-loop стенд.

До stable:

- [ ] Зафиксированы model code, board name, flash/NAND vendor, stock firmware и исходный layout.
- [ ] Снят recovery backup и доказан recovery path.
- [ ] Пройден Factory provisioning в stock layout.
- [ ] Пройден legacy baseline → `0.7.11` update.
- [ ] Проверены WAN, LAN, Wi-Fi 2.4/5 GHz, reboot, reset и повторный setup.
- [ ] Проверены commit и exact rollback.
- [ ] Выполнены контролируемые power interruption tests на mutating update states.
- [ ] После recovery повторная установка проходит успешно.

DNS-устройство SHOULD сохраняться как stock-layout lab fixture. Оно MUST NOT необратимо переводиться в ubootmod, пока для stock regression не назначен другой постоянный стенд.

## 4.5. Non-goals `0.7.11`

В `0.7.11` MUST NOT добавляться:

- новый Router UI `0.8`;
- новая навигационная архитектура;
- новые продуктовые страницы;
- динамическая установка AdGuard;
- крупный localization refactor;
- новый onboarding UX;
- новые hardware profiles без отдельного evidence;
- dependency/toolchain upgrades, не требуемые blocker fix;
- общий code cleanup «заодно».

## 4.6. Правило текущего RC

Текущий `0.7.11-rc.*` MAY быть продвинут только если его exact bytes проходят все gates без изменения.

Если меняется хотя бы один из следующих элементов, MUST быть создан следующий RC номер:

- source code;
- feed lock;
- signing identity;
- build/staging script;
- package/image bytes;
- Factory contract;
- release manifest/provenance, влияющие на проверку.

Нельзя «допатчить» или перезалить существующий RC.

## 4.7. Rollout `0.7.11`

### Ring 0 — private staging

- Signed immutable artifacts.
- Полная VM-матрица.
- Factory import.
- Никакой public stable discovery.

### Ring 1 — owner-controlled hardware canary

- DNS RD23 на точных staged bytes.
- Update, reboot, commit, rollback, recovery и power interruption.
- Никакой пересборки между VM и hardware tests.

### Ring 2 — manual stable

- Те же bytes и signatures.
- Явная release note: `0.7.11` является обязательным bridge к `0.8.x`.
- Автоматическое массовое обновление не включается одновременно с первой публикацией.

### Ring 3 — normal discovery

Разрешён только после успешного наблюдения Ring 2 и отсутствия blocker reports. Любая исправляющая пересборка становится новым patch/RC, а не заменой assets.

## 4.8. Exit criteria `0.7.11`

`0.7.11` готов к stable только когда:

- [ ] production trust root зафиксирован;
- [ ] exact supported-upgrade matrix пройдена;
- [ ] rollback и recovery доказаны;
- [ ] Factory schema 2 пройден на реальных artifacts;
- [ ] clean double build воспроизводим;
- [ ] DNS RD23 hardware gate пройден;
- [ ] нет открытых security, data-loss, updater-contract или release-integrity blockers;
- [ ] опубликован rollback/rescue runbook.

---

# 5. Release `0.8.0-dev2`

## 5.1. Цель

`0.8.0-dev2` — чистая hardening-сборка после `dev1`. Она закрывает security, updater, privacy, Factory и reproducibility blockers. Новые пользовательские функции запрещены.

## 5.2. Подготовка ветки

- [ ] Актуальный `origin/main` интегрирован реальным merge/reconciliation.
- [ ] RC1 ancestry линии `0.7.11` сохранена и проверена.
- [ ] Работа ведётся из clean worktree.
- [ ] Все изменения после audited `e20d738` разделены на понятные reviewable commits.
- [ ] `dev1` artifacts исключены из release discovery.

## 5.3. Security scope

### Setup boundary

- [ ] Public setup CGI разрешает initial setup только при `complete=false`.
- [ ] После completion public `language-set`, `reopen`, `apply` и любые mutations возвращают отказ.
- [ ] Intentional reopen запускается только authenticated LuCI RPC/API.
- [ ] Reopen создаёт token в volatile storage с коротким TTL.
- [ ] Token одноразовый и потребляется до начала mutation.
- [ ] Повторное использование, истечение и подмена token fail closed.
- [ ] Добавлены unauthenticated-LAN negative tests.

### LuCI/helper ACL boundary

- [ ] Read-only и mutating API технически разделены.
- [ ] Read-only ACL не может выполнять reset/update/configuration/setup/password commands.
- [ ] Предпочтительный дизайн: отдельные helpers или ubus methods с method-level ACL.
- [ ] Добавлены read-only-user negative tests для каждой mutating command family.

## 5.4. Updater scope

- [ ] Определён один versioned machine-tested status JSON schema.
- [ ] Initial status до первого storage preflight всегда является валидным JSON.
- [ ] Backend и UI используют один контракт полей и состояний.
- [ ] Реализованы различимые состояния:
  - offline;
  - no compatible release;
  - current version ahead;
  - update available;
  - insufficient persistent space;
  - insufficient `/tmp`;
  - downloading;
  - verifying;
  - applying;
  - validating;
  - rolling back;
  - failed;
  - success / LuCI restarting.
- [ ] `compatible_release`, `current_ahead`, `released_at`, `changelog` либо официально входят в schema и эмитятся backend, либо UI перестаёт их ожидать.
- [ ] Apply error сохраняет backend error code/message и не маскируется reload-сообщением.
- [ ] Добавлены tests: initial, cached, offline, incompatible, ahead, boundary storage, insufficient `/tmp`, apply failure и rollback.

## 5.5. Privacy scope

- [ ] `router_id_short` и любые persistent correlatable identifiers удалены из support diagnostics.
- [ ] Для конкретного bundle MAY создаваться случайный ephemeral `bundle_id`.
- [ ] `bundle_id` не сохраняется на устройстве после формирования bundle.
- [ ] Privacy allowlist test проверяет полный archive content.

## 5.6. Factory scope

- [ ] Production contracts используют только schema 2.
- [ ] Contract генерируется непосредственно из final staged artifacts.
- [ ] Каждый variant содержит detached signature, publication/prerelease fields и image-package-manifest digest.
- [ ] Реализована явная строго валидируемая пара:

```yaml
router_version: 0.8.0-dev2
factory_semver: 0.8.0-dev.2
normalization: explicit-dev-v1
```

- [ ] Numeric dev component обязан совпадать; произвольная string replacement запрещена.
- [ ] Stable/RC identities не допускают неоднозначной нормализации.
- [ ] Current Factory import и handoff проходят end-to-end.

## 5.7. Reproducibility scope

- [ ] Staging script отказывается работать из dirty checkout.
- [ ] Provenance записывает staging-script commit.
- [ ] Release manifests генерируются только после окончательной staging operation.
- [ ] IPKs и images собраны дважды и сравнены.
- [ ] Build evidence относится к exact artifact hashes.

## 5.8. AdGuard/storage scope

### Решение для `0.8.0`

Динамическая установка AdGuard не входит в `0.8.0`.

- [ ] Runtime installer выключен или fail closed с понятным reason code.
- [ ] RD23 stock и ubootmod default profiles не содержат AdGuard.
- [ ] Опциональные пакеты не могут потребить update rollback reserve.
- [ ] Точный persistent updater gate остаётся не ниже `1,680,384` bytes.
- [ ] Точный `/tmp` updater gate остаётся не ниже `1,131,520` bytes.
- [ ] Никакая процентная эвристика 90/95% не считается достаточной проверкой reserve.
- [ ] Отдельный x86 profile MAY включать AdGuard baked-in только при собственных boot/storage tests и явной variant identity.

## 5.9. Non-goals `dev2`

`dev2` MUST NOT включать:

- перестройку общей навигации;
- косметический redesign;
- новую onboarding functionality;
- новый dynamic AdGuard installer;
- новые package categories;
- расширение Factory за пределы schema-2 release contract;
- unrelated refactors;
- dependency upgrades без blocker justification.

## 5.10. Exit criteria `dev2`

- [ ] Все security P0 закрыты и покрыты negative tests.
- [ ] Updater schema согласована и тестируется end-to-end.
- [ ] Privacy contract проходит allowlist tests.
- [ ] Factory schema 2 импортируется current Factory.
- [ ] Clean double build совпадает.
- [ ] Dynamic AdGuard install отсутствует или fail closed.
- [ ] Нет открытых release-integrity blockers.

---

# 6. Release `0.8.0-dev3`

## 6.1. Цель

`0.8.0-dev3` исправляет полноту уже заявленного пользовательского опыта: RU/EN localization, input normalization, mobile layout, support form state и корректное управление уже установленным AdGuard.

Это не feature expansion release.

## 6.2. Localization scope

- [ ] Exact-text DOM translation заменена stable message IDs и параметрами.
- [ ] Переведены все wizard states, review values, backend errors, completion/reset phases и result codes.
- [ ] Переведён заявленный Tailscale и AdGuard copy.
- [ ] Все требуемые стандартные LuCI Russian catalogs включены в immutable feed lock.
- [ ] Automated coverage обнаруживает untranslated source strings.
- [ ] RU и EN проходят один и тот же functional walkthrough.

## 6.3. Input handling

- [ ] Hostname, SSID, URLs и другие trimmed fields нормализуются до validation и submission.
- [ ] Client и backend используют одинаковые normalization rules.
- [ ] Hidden leading/trailing whitespace не может пройти client validation и упасть только на backend.
- [ ] Добавлены boundary tests для пустых, whitespace-only, Unicode и максимальных значений.

## 6.4. Mobile scope

- [ ] Wizard корректно работает на widths 375, 390 и 430 px.
- [ ] Step labels не обрезаются `nowrap/overflow:hidden` без доступной альтернативы.
- [ ] Footer учитывает bottom safe area.
- [ ] Sticky controls не перекрывают содержимое Safari/Chrome UI.
- [ ] Меню и формы не создают горизонтальный scroll.
- [ ] Сохранены RU и EN screenshots для ключевых шагов.

## 6.5. Support form scope

- [ ] Diagnostics preview не уничтожает title, description, category и request type.
- [ ] Повторный preview идемпотентен.
- [ ] Privacy allowlist применяется и к preview, и к downloadable bundle.

## 6.6. Existing AdGuard management scope

Только для случая, когда AdGuard уже присутствует в конкретном profile:

- [ ] Storage card остаётся видимой после установки.
- [ ] UI показывает free space, updater reserve и AdGuard footprint раздельно.
- [ ] Customer-facing URL использует достижимый hostname/IP, а не `0.0.0.0`.
- [ ] VM profile при необходимости имеет явный port mapping для panel test.
- [ ] Query-log status читается section-aware из `querylog`.
- [ ] Filter count считается структурно только по реальным filters.
- [ ] Upstreams и enabled flags парсятся section-aware.

Runtime installation всё ещё остаётся вне scope.

## 6.7. Onboarding scope

- [ ] Item definitions имеют один authoritative versioned catalog.
- [ ] JSON и backend shell не содержат независимых расходящихся копий каталога.
- [ ] Catalog version проверяется тестами и миграцией.

## 6.8. Navigation decision

Для `0.8.0` сохраняется существующая route architecture.

Разрешено:

- исправлять broken links;
- добавлять hidden compatibility aliases;
- исправлять ACL/visibility defects текущих routes;
- обеспечивать доступность всех заявленных страниц.

DEFERRED в `0.8.1+`:

- полная консолидация VPN, Tailscale, AdGuard, Update, Setup, What’s New, Support, Settings и Reset под новым разделом `Premier Router`;
- крупная переработка menu hierarchy;
- удаление старых routes.

Причина defer: изменение общей навигации одновременно затрагивает routes, aliases, ACL и discoverability и не требуется для исправления release blockers.

## 6.9. Non-goals `dev3`

- новые setup steps;
- новые VPN capabilities;
- новая dynamic package installation architecture;
- полная navigation migration;
- визуальный redesign вне исправления usability defects;
- расширение support workflow за пределы сохранения состояния и privacy;
- unrelated cleanup.

## 6.10. Exit criteria `dev3`

- [ ] RU/EN functional parity доказана.
- [ ] Mobile matrix 375/390/430 пройдена.
- [ ] Input normalization едина на client/backend.
- [ ] Support form state сохраняется.
- [ ] Existing AdGuard management отображает корректные данные.
- [ ] Onboarding catalog имеет один source of truth.
- [ ] Не добавлено новых функций вне зафиксированного scope.

---

# 7. Release `0.8.0-rc.1`

## 7.1. Цель

RC фиксирует feature-complete и scope-frozen продукт. После cut RC разрешены только исправления blocker defects, найденных в validation matrix.

## 7.2. Entry criteria

- [ ] `0.7.11` release contract и upgrade bridge готовы.
- [ ] Все `dev2` exit criteria выполнены.
- [ ] Все `dev3` exit criteria выполнены.
- [ ] Нет открытых security, privacy, data-loss, updater-contract, Factory или reproducibility blockers.
- [ ] Final candidate собран из clean frozen commit.
- [ ] Candidate artifacts подписаны и имеют schema-2 Factory contracts.

## 7.3. Обязательная VM-матрица

На exact RC bytes:

- [ ] Clean direct `0.8` image installation.
- [ ] Factory-provisioned locked `0.7.11` VM.
- [ ] `0.7.11 → 0.8 RC → commit → reboot`.
- [ ] `0.7.11 → 0.8 RC → exact rollback`.
- [ ] Vanilla core+LuCI without optional product packages.
- [ ] Setup add/remove и повторный setup через authenticated reopen.
- [ ] Language selection with setup и без setup.
- [ ] RU/EN mobile walkthrough.
- [ ] Initial/cached/offline/ahead/incompatible updater states.
- [ ] Insufficient persistent space injection.
- [ ] Insufficient `/tmp` injection.
- [ ] Support bundle privacy validation.
- [ ] Read-only LuCI negative matrix.
- [ ] Unauthenticated-LAN negative matrix.
- [ ] Current Factory schema-2 import, provisioning и handoff.

## 7.4. DNS RD23 hardware-матрица для RC

DNS unit является достаточным hardware gate для `0.8.0-rc.1` stock variant, но не заменяет acceptance реальной китайской партии для stable.

На exact RC bytes:

- [ ] Clean stock provisioning.
- [ ] First boot и RU/EN setup.
- [ ] WAN DHCP и фактический internet access.
- [ ] LAN switching.
- [ ] Wi-Fi 2.4 GHz и 5 GHz join/traffic/reconnect.
- [ ] VPN core workflows.
- [ ] Tailscale workflows, если заявлены данным profile.
- [ ] Update check, apply, reboot и post-update validation.
- [ ] Commit и exact rollback.
- [ ] Factory reset и повторный setup.
- [ ] Recovery from failed update.
- [ ] Контролируемые power interruptions в выбранных mutating states.
- [ ] Storage gates на реальном flash.
- [ ] Температура/стабильность под длительной нагрузкой без необъяснимого reboot.

## 7.5. RC change policy

После `rc.1` разрешены только:

- security fix;
- data-loss/recovery fix;
- updater/rollback contract fix;
- Factory/reproducibility fix;
- regression, делающий заявленный workflow неработоспособным;
- localization/mobile defect, блокирующий completion заявленного workflow.

Любой fix создаёт новый `rc.N` и требует повторения затронутой матрицы плюс обязательного smoke на всех публикуемых variants.

Новые функции, refactors и UX improvements без blocker severity запрещены.

---

# 8. Release `0.8.0` stable

## 8.1. Цель

Опубликовать только те variants, чья production readiness доказана на точных или строго эквивалентных release bytes.

## 8.2. Hardware gates

### DNS RD23

Используется для постоянной destructive regression и RC validation.

### China unit #1

Назначение: production-batch stock acceptance.

- [ ] Сопоставлена hardware identity с DNS unit.
- [ ] Зафиксированы flash/NAND vendor и board revision.
- [ ] Пройден clean stock Factory → setup → update → rollback путь.
- [ ] Пройден длительный golden customer workflow.

**RD23 stock `0.8.0` stable MUST NOT публиковаться до прохождения China unit #1.**

### China unit #2

Назначение: ubootmod и recovery.

- [ ] Пройден отдельный ubootmod installation/recovery runbook.
- [ ] Пройден update/rollback в ubootmod layout.
- [ ] Доказан возврат из failed state.

**RD23 ubootmod variant MUST NOT публиковаться без этого evidence.** Если gate не готов к `0.8.0`, variant переносится в следующий release и не добавляется к уже выпущенному tag.

### China unit #3

Назначение: golden customer journey с минимальными лабораторными вмешательствами.

- [ ] Factory provisioning.
- [ ] First boot setup.
- [ ] Handoff как клиентскому устройству.
- [ ] Обычное обновление и rollback без developer-only процедур.

China unit #3 SHOULD подтверждать финальный stock release, но критический минимальный stable gate — успешный unit #1 плюс отсутствие расхождений hardware identity.

## 8.3. Final build policy

Предпочтительно продвигать неизменяемые candidate bytes.

Если stable version metadata требует новой сборки:

- source commit остаётся frozen;
- допустимы только version/publication metadata changes;
- создаётся новый полный provenance;
- double build повторяется;
- Factory contracts и signatures генерируются заново;
- обязательный VM smoke и DNS hardware smoke повторяются;
- hash equivalence с RC не утверждается.

## 8.4. Stable exit criteria

- [ ] Все RC blockers закрыты.
- [ ] Final artifacts собраны reproducibly.
- [ ] Current Factory принимает final schema-2 contracts.
- [ ] `0.7.11 → 0.8.0 → commit → rollback` пройден на final bytes.
- [ ] DNS hardware smoke пройден на final bytes.
- [ ] China production-batch stock gate пройден.
- [ ] Каждый публикуемый variant имеет собственный hardware evidence.
- [ ] Release notes содержат supported paths, non-supported paths и rescue/rollback instructions.
- [ ] Dynamic AdGuard installation не рекламируется и не доступна.
- [ ] Нет assets без честного verification status.

---

# 9. Явно отложено в `0.8.1+`

Следующие задачи не должны попадать в `0.7.11` или `0.8.0`, если только не обнаружится прямой security/release blocker:

- полная консолидация страниц под `Premier Router`;
- удаление старых routes после периода aliases;
- production dynamic AdGuard installer;
- измерение и поддержка полного AdGuard download/feed/install `/tmp` peak;
- новые optional package installers;
- расширенная storage analytics;
- крупный visual redesign;
- новые setup/onboarding steps;
- новые hardware profiles;
- общий cleanup/refactor без пользовательского blocker;
- dependency/toolchain upgrades ради актуальности;
- новые Factory capabilities за пределами текущего schema-2 contract;
- новые support ticket capabilities;
- дополнительные локали помимо уже заявленных RU/EN;
- performance optimization без воспроизводимого regression и acceptance threshold.

Backlog item может быть повышен только отдельным изменением этого scope с явным ответом:

1. Какой текущий release goal он разблокирует?
2. Какой acceptance criterion без него невозможно пройти?
3. Почему безопасное отключение или перенос недостаточны?
4. Какие новые риски и тесты он добавляет?

---

# 10. Triage новых дефектов

| Тип находки | Текущий релиз | Решение |
|---|---|---|
| Remote unauthenticated mutation, privilege escalation | Да | Blocker, исправить немедленно |
| Data loss, невозможный rollback/recovery | Да | Blocker |
| Неверная подпись, provenance, Factory или artifact identity | Да | Blocker |
| Updater выдаёт невалидный contract или может применить неподходящий release | Да | Blocker |
| Нарушение privacy contract support bundle | Да | Blocker до public release |
| Заявленный основной workflow не завершается | Да | Regression blocker |
| RU/EN или mobile defect мешает завершить заявленный workflow | Да для `dev3/RC` | Исправить |
| Cosmetic defect с безопасным workaround | Нет | `0.8.1+` |
| Архитектурный refactor без обязательного defect fix | Нет | `0.8.1+` |
| Новая функция или новый package/profile | Нет | Отдельный будущий scope |
| Performance idea без baseline и threshold | Нет | Backlog |
| Улучшение developer convenience, меняющее release tooling | Только если блокирует reproducibility | Иначе backlog |

---

# 11. Правила работы Codex

Перед каждой задачей Codex MUST зафиксировать в рабочем описании:

```text
Target release:
Release goal:
Acceptance criterion closed:
Why the release cannot ship safely without this change:
Tests/evidence to add or update:
```

Если поля `Acceptance criterion closed` и `Why ... cannot ship` нельзя заполнить конкретно, задача считается вне текущего scope.

Дополнительные правила:

1. Один defect — один логически изолированный commit, если это практически возможно.
2. Security fix обязательно включает negative test.
3. Contract fix обязательно включает schema/fixture test и end-to-end consumer test.
4. UI fix обязательно включает функциональную проверку, а не только screenshot.
5. Build/release fix обязательно проверяется из чистого checkout.
6. Не использовать uncommitted local scripts как release input.
7. Не менять dependencies, toolchain или feed lock в рамках unrelated fix.
8. Не улучшать соседний код «заодно».
9. При обнаружении дополнительной проблемы создать отдельный backlog item; не расширять текущий patch без blocker-классификации.
10. Если необязательная функция угрожает сроку или доказуемости, отключить её и задокументировать defer.

---

# 12. Минимальный evidence bundle каждого кандидата

Каждый RC/stable candidate MUST иметь:

- source commit и branch/ref;
- clean-worktree proof;
- build/staging script commit;
- toolchain/ImageBuilder version;
- feed lock;
- package manifest;
- image manifest;
- SHA-256 каждого asset;
- detached signatures;
- Factory schema-2 contracts;
- double-build comparison result;
- automated test report;
- VM scenario report;
- hardware report для каждого публикуемого hardware variant;
- known limitations;
- rollback/rescue instructions;
- явный verification label: `vm-only`, `hardware-validated`, `stock-validated`, `ubootmod-validated` или `test-only`.

Label MUST отражать фактическое evidence. `Static checks passed` не эквивалентно `hardware-validated`.

---

# 13. Краткий release checklist

## `0.7.11`

- [ ] Scope frozen как bridge-only.
- [ ] Production trust root.
- [ ] Locked images/IPKs.
- [ ] Schema-2 Factory contracts.
- [ ] Legacy VM upgrade matrix.
- [ ] Exact rollback/recovery.
- [ ] DNS RD23 stock hardware gate.
- [ ] Ringed rollout без замены bytes.

## `0.8.0-dev2`

- [ ] Setup security boundary.
- [ ] Read/write ACL split.
- [ ] Updater schema and error integrity.
- [ ] Privacy identifier removal.
- [ ] Schema-2 Factory and explicit version mapping.
- [ ] Clean reproducible staging.
- [ ] Dynamic AdGuard installer disabled.

## `0.8.0-dev3`

- [ ] RU/EN message-ID localization.
- [ ] Standard LuCI RU catalogs.
- [ ] Input normalization.
- [ ] Mobile 375/390/430 and safe area.
- [ ] Support form state preservation.
- [ ] Correct existing AdGuard status/URL parsing.
- [ ] Single onboarding catalog.
- [ ] Navigation consolidation remains deferred.

## `0.8.0-rc.1`

- [ ] Full VM matrix on exact bytes.
- [ ] Full DNS RD23 stock matrix.
- [ ] No feature changes.
- [ ] Signed immutable artifacts.

## `0.8.0` stable

- [ ] Final reproducible build.
- [ ] Final VM and DNS smoke.
- [ ] China production-batch stock acceptance.
- [ ] Separate evidence for every published variant.
- [ ] Ubootmod omitted unless independently validated.
- [ ] Release notes and rescue path complete.

---

# 14. Зафиксированные решения

1. DNS RD23 заказан и используется как постоянный destructive stock-layout hardware fixture.
2. `0.8.0-dev1` остаётся test-only snapshot и не продвигается.
3. `0.7.11` выпускается отдельно как trust/update bridge.
4. Каждый dev build не требует hardware run; каждый RC и public hardware release требует.
5. `0.8.0-rc.1` может быть собран после успешного DNS RD23 прогона.
6. RD23 `0.8.0` stable ждёт минимум одно устройство из фактической китайской партии.
7. Dynamic AdGuard installation исключена из `0.8.0`.
8. Полная migration навигации под `Premier Router` исключена из `0.8.0` и переносится в `0.8.1+`.
9. Variant без hardware evidence не публикуется и не добавляется задним числом к release.
10. Любое расширение scope требует отдельного изменения этого документа, а не скрытого расширения implementation task.
