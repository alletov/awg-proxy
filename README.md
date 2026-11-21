# AWG Home

Интерактивный установщик и менеджер домашнего интернет-шлюза через
[AmneziaWG](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module).

AWG Home превращает отдельный Ubuntu-сервер в шлюз для разрешённых локальных
сетей, поднимает SOCKS5 и локальный DNS, а затем позволяет управлять ими через
единое консольное меню.

> Проект находится на ранней стадии. Перед использованием нужен консольный или
> out-of-band доступ к серверу. Не запускайте сетевой установщик на удалённой
> машине, к которой у вас есть только одна SSH-сессия.

## Возможности

- импорт готовой клиентской конфигурации AmneziaWG;
- защищённый маршрут к AWG endpoint через обычный LAN-шлюз;
- раздельные списки сетей для VPN forwarding, локальных сервисов и частных
  маршрутов;
- IPv4 forwarding, masquerade, stateful-фильтрация и TCP MSS clamp в nftables;
- запрет новых соединений из VPN-туннеля в LAN;
- Dante SOCKS5 на LAN-адресе с выходом только через `awg0`;
- Unbound DNS только на loopback и LAN-адресе;
- автозапуск через systemd и восстановление после рестарта networkd;
- автоматический rollback сетевых изменений через пять минут;
- статусы, проверки, счётчики трафика, диагностика, backup и безопасный reboot;
- повторный мастер для изменения настроек.

AWG Home создаёт только собственные nftables-таблицы `awghome_filter` и
`awghome_nat`. Он не очищает и не переписывает сторонние firewall-таблицы при
штатном применении конфигурации.

## Требования

- Ubuntu Server 22.04 или 24.04;
- root-доступ (`sudo`);
- systemd и IPv4 LAN;
- готовая клиентская конфигурация AmneziaWG с `PrivateKey`, `Endpoint` и
  `AllowedIPs`;
- LAN-шлюз, через который доступны endpoint и частные сети;
- желательно две SSH-сессии и обязательный консольный/out-of-band доступ.

В первой версии поддерживается только IPv4. Netplan установщик не изменяет.

## Быстрый запуск из GitHub

Установите проект одной командой:

```bash
curl -fsSL https://raw.githubusercontent.com/alletov/awg-proxy/main/install.sh \
  -o /tmp/awghome-install.sh
sudo bash /tmp/awghome-install.sh
```

Вариант без изменения `install.sh`:

```bash
sudo AWGHOME_REPO=alletov/awg-proxy bash /tmp/awghome-install.sh
```

Скачивание в отдельный файл сделано намеренно: пользователь может проверить
скрипт до запуска от root. Конструкция `curl | sudo bash` не рекомендуется.

Для локальной разработки:

```bash
sudo bash ./install.sh
```

Основной менеджер устанавливается как команда `awghome`.

## Управление

```text
awghome                 интерактивное меню
awghome status          состояние сервисов, туннеля и сокетов
awghome check           полный readiness-check
awghome stats           AWG и nftables-счётчики
awghome report          сохранить диагностический отчёт без секретов
awghome config          настройки без секретов
awghome change          повторный мастер конфигурации
awghome restart         перезапуск управляемых сервисов
awghome diagnose        read-only диагностика
awghome backup          резервная копия конфигурации и сетевого состояния
awghome reboot          проверка и подтверждённая перезагрузка
```

## Что изменяется на сервере

- `/opt/awghome` и `/usr/local/sbin/awghome`;
- `/etc/awghome/awghome.conf` и nftables-конфигурация проекта;
- `/etc/amnezia/amneziawg/awg0.conf` с правами `0600`;
- `/etc/unbound/unbound.conf.d/awghome.conf`;
- `/etc/danted.conf`;
- `/etc/sysctl.d/90-awghome-forwarding.conf`;
- systemd units/drop-ins `awghome-*`, `awg-quick@awg0` и `danted`;
- вспомогательные скрипты в `/usr/local/lib/awghome`;
- резервные копии в `/var/backups/awghome`.

Устанавливаемые пакеты: AmneziaWG из официального PPA проекта, nftables,
Unbound, Dante, заголовки текущего ядра и необходимые системные зависимости.

## Модель маршрутизации

`LAN_PREFIX` — единственная непосредственно подключённая локальная сеть.
Широкие частные диапазоны не объявляются подключёнными к LAN: они получают
маршруты через `LAN_GW`. Более точный connected-маршрут LAN сохраняет приоритет.

- `PRIVATE_ROUTES` — назначения, остающиеся вне AWG;
- `VPN_CLIENT_NETWORKS` — источники, которым разрешены forwarding и NAT через
  `awg0`;
- `SERVICE_CLIENT_NETWORKS` — источники, которым разрешены DNS и SOCKS5.

Эти списки независимы, даже если по умолчанию имеют одинаковые значения.

## Безопасность и rollback

До сетевых изменений сохраняются маршруты, policy rules, nftables ruleset и
затрагиваемые конфиги. Затем systemd запускает пятиминутный rollback-таймер.
Таймер отменяется только после успешной проверки AWG handshake, маршрута к
endpoint, forwarding, firewall и локальных сервисов.

Приватный ключ никогда не выводится командой `awghome config`. Конфигурация
туннеля доступна только root. В логах проекта секреты также не печатаются.

## Разработка

CI выполняет синтаксическую проверку Bash, ShellCheck и Bats-тесты:

```bash
bash -n install.sh awghome.sh lib/*.sh
shellcheck install.sh awghome.sh lib/*.sh
bats tests
```

Интеграционные тесты nftables, systemd и реального AWG необходимо проводить на
одноразовой Ubuntu VM с консольным доступом. Unit-тесты не доказывают
безопасность изменения маршрутов на конкретном сервере.

## Лицензия

MIT. Архитектурная идея «bootstrap + установленный консольный менеджер» взята
из проекта [MTProxyL](https://github.com/Liafanx/MTProxyL); его исходный код в
AWG Home не копировался.
