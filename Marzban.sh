#!/bin/bash

# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo "Запустите скрипт от имени root: sudo $0"
  exit 1
fi

# Проверка ОС
if ! grep -q "Ubuntu 24.04" /etc/os-release; then
  echo "Скрипт предназначен для Ubuntu 24.04. Текущая ОС: $(cat /etc/os-release | grep PRETTY_NAME)"
  exit 1
fi

# Запрос доменных имён
echo "Введите доменное имя для панели Marzban и сертификатов (например, example.outlinekeys.net):"
read -r PANEL_DOMAIN
if [ -z "$PANEL_DOMAIN" ]; then
  echo "Ошибка: доменное имя для панели не указано."
  exit 1
fi

echo "Введите доменное имя для маскировки VLESS REALITY (например, ladies.de или example.com):"
read -r REALITY_DOMAIN
if [ -z "$REALITY_DOMAIN" ]; then
  echo "Ошибка: доменное имя для VLESS REALITY не указано."
  exit 1
fi

# Установка зависимостей
echo "Установка зависимостей..."
apt update
apt install -y curl socat git docker.io docker-compose cron nano wget

# Установка Marzban
echo "Установка Marzban..."
bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install

# Настройка сертификатов Let’s Encrypt
echo "Получение сертификатов Let’s Encrypt для $PANEL_DOMAIN..."
mkdir -p /var/lib/marzban/certs
curl https://get.acme.sh | sh -s email=snyppi@ya.ru
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --issue --standalone -d "$PANEL_DOMAIN" \
  --key-file /var/lib/marzban/certs/key.pem \
  --fullchain-file /var/lib/marzban/certs/fullchain.pem

# Настройка .env
echo "Настройка .env для Marzban..."
cat << EOF > /opt/marzban/.env
UVICORN_HOST = "0.0.0.0"
UVICORN_PORT = 443
ALLOWED_ORIGINS=http://localhost,http://localhost:8000,http://$PANEL_DOMAIN
UVICORN_SSL_CERTFILE = "/var/lib/marzban/certs/fullchain.pem"
UVICORN_SSL_KEYFILE = "/var/lib/marzban/certs/key.pem"
XRAY_JSON = "/var/lib/marzban/xray_config.json"
XRAY_SUBSCRIPTION_URL_PREFIX = "https://$PANEL_DOMAIN"
CUSTOM_TEMPLATES_DIRECTORY="/var/lib/marzban/templates/"
SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"
SUB_PROFILE_TITLE = "SnyppiVPN"
SUB_SUPPORT_URL = "https://t.me/SnyppiVPN_support"
SUB_UPDATE_INTERVAL = "6"
SQLALCHEMY_DATABASE_URL = "sqlite:////var/lib/marzban/db.sqlite3"
EOF

# Установка страницы подписки
echo "Установка кастомной страницы подписки..."
mkdir -p /var/lib/marzban/templates/subscription
wget -N -P /var/lib/marzban/templates/subscription/ https://raw.githubusercontent.com/Snyppi/sub/main/index.html

# Создание администратора
echo "Создание администратора Marzban..."
marzban cli admin create --sudo

# Генерация privateKey и shortId
echo "Генерация privateKey и shortId для VLESS REALITY..."
PRIVATE_KEY=$(docker exec marzban-marzban-1 xray x25519 | grep "Private key" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)
if [ -z "$PRIVATE_KEY" ] || [ -z "$SHORT_ID" ]; then
  echo "Ошибка: не удалось сгенерировать privateKey или shortId."
  exit 1
fi

# Настройка xray_config.json
echo "Настройка Xray конфигурации..."
cat << EOF > /var/lib/marzban/xray_config.json
{
    "log": {
        "loglevel": "info"
    },
    "inbounds": [
        {
            "tag": "VMess TCP",
            "listen": "0.0.0.0",
            "port": 8081,
            "protocol": "vmess",
            "settings": {
                "clients": []
            },
            "streamSettings": {
                "network": "tcp",
                "tcpSettings": {
                    "header": {
                        "type": "http",
                        "request": {
                            "method": "GET",
                            "path": ["/"],
                            "headers": {
                                "Host": ["google.com"]
                            }
                        },
                        "response": {}
                    }
                },
                "security": "none"
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        },
        {
            "tag": "VMess Websocket",
            "listen": "0.0.0.0",
            "port": 8080,
            "protocol": "vmess",
            "settings": {
                "clients": []
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "/",
                    "headers": {
                        "Host": "google.com"
                    }
                },
                "security": "none"
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        },
        {
            "tag": "VLESS TCP REALITY",
            "listen": "0.0.0.0",
            "port": 8444,
            "protocol": "vless",
            "settings": {
                "clients": [],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "tcpSettings": {},
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "$REALITY_DOMAIN:443",
                    "xver": 0,
                    "serverNames": ["$REALITY_DOMAIN"],
                    "privateKey": "$PRIVATE_KEY",
                    "shortIds": ["$SHORT_ID"]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        },
        {
            "tag": "VLESS GRPC REALITY",
            "listen": "0.0.0.0",
            "port": 2053,
            "protocol": "vless",
            "settings": {
                "clients": [],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "grpc",
                "grpcSettings": {
                    "serviceName": "xyz"
                },
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "discordapp.com:443",
                    "xver": 0,
                    "serverNames": ["cdn.discordapp.com", "discordapp.com"],
                    "privateKey": "$PRIVATE_KEY",
                    "shortIds": ["", "$SHORT_ID"]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        },
        {
            "tag": "Trojan Websocket TLS",
            "listen": "0.0.0.0",
            "port": 2083,
            "protocol": "trojan",
            "settings": {
                "clients": []
            },
            "streamSettings": {
                "network": "ws",
                "security": "tls",
                "tlsSettings": {
                    "certificates": [
                        {
                            "certificate": [
                                "-----BEGIN CERTIFICATE-----",
                                "MIIBvTCCAWOgAwIBAgIRAIY9Lzn0T3VFedUnT9idYkEwCgYIKoZIzj0EAwIwJjER",
                                "MA8GA1UEChMIWHJheSBJbmMxETAPBgNVBAMTCFhyYXkgSW5jMB4XDTIzMDUyMTA4",
                                "NDUxMVoXDTMzMDMyOTA5NDUxMVowJjERMA8GA1UEChMIWHJheSBJbmMxETAPBgNV",
                                "BAMTCFhyYXkgSW5jMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEGAmB8CILK7Q1",
                                "FG47g5VXg/oX3EFQqlW8B0aZAftYpHGLm4hEYVA4MasoGSxRuborhGu3lDvlt0cZ",
                                "aQTLvO/IK6NyMHAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMB",
                                "MAwGA1UdEwEB/wQCMAAwOwYDVR0RBDQwMoILZ3N0YXRpYy5jb22CDSouZ3N0YXRp",
                                "Yy5jb22CFCoubWV0cmljLmdzdGF0aWMuY29tMAoGCCqGSM49BAMCA0gAMEUCIQC1",
                                "XMIz1XwJrcu3BSZQFlNteutyepHrIttrtsfdd05YsQIgAtCg53wGUSSOYGL8921d",
                                "KuUcpBWSPkvH6y3Ak+YsTMg=",
                                "-----END CERTIFICATE-----"
                            ],
                            "key": [
                                "-----BEGIN RSA PRIVATE KEY-----",
                                "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg7ptMDsNFiL7iB5N5",
                                "gemkQUHIWvgIet+GiY7x7qB13VDFTANCAAQYCYHwIgsrtDUUbjuDlVeD+hfcQVCq",
                                "VbwHRpkB+1ikcYubiERhUDgxqygZLFG5uiuEa7eUO+W3RxlpBMu878gr",
                                "-----END RSA PRIVATE KEY-----"
                            ]
                        }
                    ],
                    "minVersion": "1.2",
                    "cipherSuites": "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        },
        {
            "tag": "Shadowsocks TCP",
            "listen": "0.0.0.0",
            "port": 1081,
            "protocol": "shadowsocks",
            "settings": {
                "clients": [],
                "network": "tcp,udp"
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "DIRECT"
        },
        {
            "protocol": "blackhole",
            "tag": "BLOCK"
        }
    ],
    "routing": {
        "rules": [
            {
                "outboundTag": "DIRECT",
                "domain": [
                    "domain:msftconnecttest.com",
                    "domain:msftncsi.com",
                    "domain:connectivitycheck.gstatic.com",
                    "domain:captive.apple.com",
                    "full:detectportal.firefox.com",
                    "domain:networkcheck.kde.org",
                    "full:*.gstatic.com"
                ],
                "type": "field"
            },
            {
                "ip": ["geoip:private"],
                "outboundTag": "BLOCK",
                "type": "field"
            },
            {
                "domain": ["geosite:private"],
                "outboundTag": "BLOCK",
                "type": "field"
            },
            {
                "protocol": ["bittorrent"],
                "outboundTag": "BLOCK",
                "type": "field"
            }
        ]
    }
}
EOF

# Перезапуск Marzban
echo "Перезапуск Marzban..."
marzban restart

# Настройка UFW
echo "Настройка UFW..."
apt install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 42905/tcp comment 'Outline Manager'
ufw allow 8443/tcp comment 'Outline Access key port (TCP)'
ufw allow 8443/udp comment 'Outline Access key port (UDP)'
ufw allow 8081/tcp comment 'VMess TCP inbound'
ufw allow 8080/tcp comment 'VMess Websocket inbound'
ufw allow 8444/tcp comment 'VLESS TCP REALITY inbound'
ufw allow 2053/tcp comment 'VLESS GRPC REALITY inbound'
ufw allow 2083/tcp comment 'Trojan Websocket TLS inbound'
ufw allow 1081/tcp comment 'Shadowsocks TCP inbound'
ufw allow 1081/udp comment 'Shadowsocks UDP inbound'
ufw allow 22/tcp comment 'SSH access'
ufw allow 80/tcp comment 'HTTP traffic'
ufw allow 443/tcp comment 'HTTPS traffic'
ufw disable && ufw enable

# Установка и настройка Fail2Ban
echo "Установка и настройка Fail2Ban..."
apt install -y fail2ban
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
cat << EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 36000
findtime = 600
maxretry = 3
backend = auto
destemail = root@localhost
sender = root@localhost
mta = sendmail
protocol = tcp
chain = INPUT
action = %(action_)s

[sshd]
enabled = true
mode = normal
port = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 5
EOF
systemctl restart fail2ban
systemctl enable fail2ban

# Проверка состояния
echo "Проверка состояния..."
echo "Marzban:"
marzban status
echo "Порты (Outline: 8443, 42905; Marzban: 443, 8444, 2053, 8080, 8081, 2083, 1081):"
ss -lnptu | grep -E '443|8443|42905|8444|2053|8080|8081|2083|1081'
echo "UFW:"
ufw status
echo "Fail2Ban:"
systemctl status fail2ban | grep Active
echo "Сертификаты:"
ls -l /var/lib/marzban/certs/
echo "Логи Marzban (последние 10 строк):"
cd /opt/marzban && docker-compose logs marzban --tail 10
echo "Лимиты открытых файлов для Docker:"
grep LimitNOFILE /etc/systemd/system/docker.service.d/override.conf || echo "Лимиты для Docker не установлены"

echo "Установка и настройка Marzban завершены!"
echo "Панель Marzban доступна по https://$PANEL_DOMAIN:443"
echo "Подключите клиентов к портам 8444 (VLESS TCP REALITY, маскировка под $REALITY_DOMAIN), 2053 (VLESS GRPC REALITY), 8080 (VMess Websocket), 8081 (VMess TCP), 2083 (Trojan), 1081 (Shadowsocks)."