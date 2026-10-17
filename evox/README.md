# Evolution X для Advan Tab V8 / Alldocube iPlay 60 mini Pro (T812)

Сборка одной командой. Скрипт синхронизирует Evolution X и деревья T812,
проверяет их, собирает прошивку и складывает файлы для прошивки в одну папку.

Ядро не собирается: используется стоковый GKI 5.10 (`android12-5.10`) и
vendor-модули из `device/advan/T812-kernel`.

## Что используется

| Путь | Репозиторий | `bka` (Android 16 QPR2) | `cnb` (Android 17) |
|---|---|---|---|
| `device/advan/T812` | diggieman/android_device_advan_T812 | `lineage-23.2` @ `945e394` | `lineage-24.0` @ `6aef88d` |
| `device/advan/T812-kernel` | diggieman/android_device_advan_T812-kernel | `cb49cb7` | `cb49cb7` |
| `vendor/advan/T812` | diggieman/android_vendor_advan_T812 | `lineage-23.2` @ `70d1803` | `lineage-24.0` @ `03ae848` |
| `vendor/mediatek/ims` | diggieman/android_vendor_mediatek_ims | `android-16-qpr2` @ `e9cab87` | то же |
| `hardware/mediatek` | MillenniumOSS/android_hardware_mediatek | `sixteen` @ `37f74a4` | `seventeen` @ `b27c726` |
| `device/mediatek/sepolicy_vndr` | MillenniumOSS/android_device_mediatek_sepolicy_vndr | `sixteen-qpr2-rebase` @ `1136b3f` | `seventeen` @ `a0d3ae0` |

Деревья из `Advan-MT6789-Resources` (включая этот репозиторий `mt6789-common`)
заархивированы. Их работу продолжил diggieman: common влит прямо в дерево T812.

Коммиты закреплены в `manifests/*.xml`. С флагом `--latest` берутся последние
коммиты веток.

## Свои копии репозиториев (рекомендуется)

Если репозитории diggieman или MillenniumOSS удалят, сборка сломается. Скрипт
`fork-repos.sh` делает форки всех репозиториев T812 со всеми ветками в ваш
аккаунт через [gh](https://cli.github.com), проверяет, что закреплённые
коммиты в форках есть, и переводит манифесты на ваши копии:

```bash
gh auth login
./evox/fork-repos.sh            # или --org ORG, --no-rewrite
git add evox/manifests && git commit -m "evox: Use forked T812 repositories" && git push
```

Повторный запуск подтягивает в существующие форки новые коммиты всех веток.

## Требования к машине

- x86_64 Linux, лучше Ubuntu 22.04/24.04
- 300+ ГБ свободного места на SSD (с `--full-history` около 450 ГБ)
- 32+ ГБ RAM + swap, лучше 64 ГБ
- чем больше ядер, тем лучше: на 16 потоках первая сборка идёт примерно 3–5 часов, повторные с ccache около 1–2 часов

## Сборка

```bash
git clone https://github.com/iArti/android_device_advan_mt6789-common
./android_device_advan_mt6789-common/evox/build.sh --install-deps
```

Результат лежит в `~/evox-bka/release/<дата>/`: `EvolutionX-*.zip`, `boot.img`,
`vendor_boot.img`, `dtbo.img`, `vbmeta.img` и `SHA256SUMS`.

Полезные флаги (полный список: `--help`):

| Флаг | Что делает |
|---|---|
| `-b cnb` | Android 17 вместо Android 16 QPR2. Ветка новая, ждите багов |
| `--vanilla` | без GApps |
| `-t user` | user-сборка вместо userdebug |
| `-d DIR` | другая папка с исходниками |
| `--latest` | последние коммиты деревьев T812 вместо закреплённых |
| `--sync-only` / `--no-sync` | только синхронизация / только сборка |
| `--clean` | `m installclean` перед сборкой |

Перезапуск безопасен: `repo sync` докачивает недостающее, ccache ускоряет
повторные сборки.

## Первая установка

Загрузчик должен быть разблокирован. В fastboot:

```bash
fastboot flash boot boot.img
fastboot flash vendor_boot vendor_boot.img
fastboot flash dtbo dtbo.img
fastboot flash vbmeta vbmeta.img
fastboot reboot recovery
```

В recovery: Factory reset → Format data, затем Apply update → adb sideload:

```bash
adb sideload EvolutionX-*.zip
```

## Что проверяет скрипт

Перед сборкой скрипт проверяет:

- манифест EvoX и локальный манифест сливаются без конфликтов путей (`repo manifest`);
- на месте ядро, dtb, dtbo и каждый модуль из `modules.load*`
  (172 + 186 для vendor_ramdisk, 168 для vendor_dlkm);
- на месте все блобы, на которые ссылаются `T812-vendor.mk` и `Android.bp`
  vendor-дерева (около 2500 файлов);
- существуют все Soong namespace из `device.mk`;
- у Evolution X есть нужный release (`bp4a` для bka, `cp2a` для cnb);
- нет недокачанных git-lfs файлов.
