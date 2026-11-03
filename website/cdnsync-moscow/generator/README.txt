Генератор одной подписки Moscow для Happ и Incy.

Файлы subgen.py, server-public.json, routing-base64.txt устанавливаются
в /opt/cdnsync-subgen с правами чтения для www-data.
Служба cdnsync-subgen.service — в /etc/systemd/system/.
Генератор слушает только 127.0.0.1:9075; Nginx проксирует
/happ.txt, /incy.txt и /config.txt.

В каждой подписке один VLESS XHTTP REALITY узел Moscow, свежий UUID,
fp=firefox, mode=auto и случайный xPaddingBytes внутри 100–1000.
В extra синхронно передаются mode и xPaddingBytes.
Правила RU Direct включены в подписку.
Требуется сервер Xray с уже настроенным приёмом произвольных UUID.
Публичные параметры клиента лежат в server-public.json; приватных
серверных ключей здесь нет. Страницы и подписки не кэшируются.

Перед установкой на другую машину проверьте IP, SNI, публичный ключ,
short ID и путь XHTTP по её работающей конфигурации Xray.
