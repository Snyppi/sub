#!/bin/bash

# --- НАСТРОЙКИ (можно изменить) ---
# IP адрес сервера-приёмника для бэкапов
REMOTE_BACKUP_IP="195.2.85.111"
# ----------------------------------

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Начало скрипта ---

# 1. Проверка root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ Запустите скрипт от имени root: sudo $0${NC}"
  exit 1
fi

# 2. Проверка ОС
if ! grep -q "Ubuntu 24.04" /etc/os-release; then
  echo -e "${YELLOW}⚠️ Скрипт предназначен для Ubuntu 24.04. Текущая ОС: $(grep PRETTY_NAME /etc/os-release | cut -d'=' -f2)${NC}"
  read -p "Продолжить на свой страх и риск? (y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    exit 1
  fi
fi

# 3. Запрос доменных имён
echo -e "${GREEN}Введите доменное имя для панели Marzban (например, panel.yourdomain.com):${NC}"
read -r PANEL_DOMAIN
if [ -z "$PANEL_DOMAIN" ]; then echo -e "${RED}❌ Ошибка: доменное имя для панели не указано.${NC}"; exit 1; fi

echo -e "${GREEN}Введите домен для маскировки VLESS TCP REALITY (например, www.microsoft.com):${NC}"
read -r VLESS_TCP_DOMAIN
if [ -z "$VLESS_TCP_DOMAIN" ]; then echo -e "${RED}❌ Ошибка: домен для VLESS TCP не указан.${NC}"; exit 1; fi

echo -e "${GREEN}Введите домен для маскировки VLESS GRPC REALITY (например, cdn.discordapp.com):${NC}"
read -r VLESS_GRPC_DOMAIN
if [ -z "$VLESS_GRPC_DOMAIN" ]; then echo -e "${RED}❌ Ошибка: домен для VLESS GRPC не указан.${NC}"; exit 1; fi

# 4. ВЫБОР ЛОКАЦИИ
LOCATION_STRING=""
while [ -z "$LOCATION_STRING" ]; do
    echo -e "\n${GREEN}Выберите локацию сервера:${NC}"
    echo "1) US 🇺🇸"; echo "2) GE 🇩🇪"; echo "3) NL 🇳🇱"; echo "4) FIN 🇫🇮"; echo "5) RU 🇷🇺"
    read -p "Введите номер (1-5): " choice
    case $choice in
        1) LOCATION_STRING="SnyppiVPN🇺🇸"; break ;; 2) LOCATION_STRING="SnyppiVPN🇩🇪"; break ;;
        3) LOCATION_STRING="SnyppiVPN🇳🇱"; break ;; 4) LOCATION_STRING="SnyppiVPN🇫🇮"; break ;;
        5) LOCATION_STRING="SnyppiVPN🇷🇺"; break ;; *) echo -e "${RED}Неверный выбор.${NC}" ;;
    esac
done
echo -e "${GREEN}✅ Выбрана локация: $LOCATION_STRING${NC}\n"

# 5. Установка зависимостей (включая Nginx и Fail2Ban)
echo -e "${GREEN}▶️ Установка всех зависимостей...${NC}"
apt update && apt install -y curl socat git docker.io docker-compose cron nano wget rsync nginx-full ufw fail2ban
if [ $? -ne 0 ]; then echo -e "${RED}❌ Ошибка установки зависимостей.${NC}"; exit 1; fi

# 6. Установка Marzban
echo -e "${GREEN}▶️ Установка Marzban...${NC}"
bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install
if [ $? -ne 0 ]; then echo -e "${RED}❌ Ошибка установки Marzban.${NC}"; exit 1; fi

# 7. Настройка сертификатов Let’s Encrypt
echo -e "${GREEN}▶️ Получение сертификатов Let’s Encrypt для $PANEL_DOMAIN...${NC}"
systemctl stop nginx # Временно останавливаем Nginx, чтобы освободить порт 80
mkdir -p /var/lib/marzban/certs
curl https://get.acme.sh | sh -s email=snyppi@ya.ru
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --issue --standalone -d "$PANEL_DOMAIN" \
  --key-file /var/lib/marzban/certs/key.pem \
  --fullchain-file /var/lib/marzban/certs/fullchain.pem
if [ $? -ne 0 ]; then echo -e "${RED}❌ Ошибка получения сертификатов. Проверьте, что домен $PANEL_DOMAIN указывает на IP этого сервера.${NC}"; exit 1; fi

# 8. Настройка .env (для работы за Nginx)
echo -e "${GREEN}▶️ Настройка .env для работы Marzban за Nginx...${NC}"
cat << EOF > /opt/marzban/.env
UVICORN_HOST = "127.0.0.1"
UVICORN_PORT = 8000
XRAY_JSON = "/var/lib/marzban/xray_config.json"
XRAY_SUBSCRIPTION_URL_PREFIX = "https://$PANEL_DOMAIN"
CUSTOM_TEMPLATES_DIRECTORY="/var/lib/marzban/templates/"
SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"
SUB_PROFILE_TITLE = "SnyppiVPN"
SQLALCHEMY_DATABASE_URL = "sqlite:////var/lib/marzban/db.sqlite3"
EOF

# 9. Установка и настройка страницы подписки
echo -e "${GREEN}▶️ Установка и настройка кастомной страницы подписки...${NC}"
mkdir -p /var/lib/marzban/templates/subscription
wget -N -P /var/lib/marzban/templates/subscription/ https://raw.githubusercontent.com/Snyppi/sub/main/index.html
SUB_TEMPLATE_FILE="/var/lib/marzban/templates/subscription/index.html"
if [ -f "$SUB_TEMPLATE_FILE" ]; then
    sed -i "s|SnyppiVPN🇩🇪|$LOCATION_STRING|g" "$SUB_TEMPLATE_FILE"
fi

# 10. Создание администратора
echo -e "${GREEN}▶️ Создание администратора Marzban...${NC}"
marzban cli admin create --sudo

# 11. Генерация ключей и настройка Xray (только VLESS)
echo -e "${GREEN}▶️ Генерация ключей и настройка Xray (только VLESS)...${NC}"
PRIVATE_KEY=$(docker exec marzban-marzban-1 xray x25519 | grep "Private key" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)
if [ -z "$PRIVATE_KEY" ] || [ -z "$SHORT_ID" ]; then echo -e "${RED}❌ Ошибка: не удалось сгенерировать ключи.${NC}"; exit 1; fi
cat << EOF > /var/lib/marzban/xray_config.json
{
    "log": {"loglevel": "info"},
    "inbounds": [
        {
            "tag": "VLESS TCP REALITY",
            "listen": "127.0.0.1",
            "port": 8444,
            "protocol": "vless",
            "settings": {"clients": [], "decryption": "none"},
            "streamSettings": {
                "network": "tcp", "security": "reality",
                "realitySettings": {"show": false, "dest": "$VLESS_TCP_DOMAIN:443", "xver": 0, "serverNames": ["$VLESS_TCP_DOMAIN"], "privateKey": "$PRIVATE_KEY", "shortIds": ["$SHORT_ID"]},
                "sockopt": { "acceptProxyProtocol": true }
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
        },
        {
            "tag": "VLESS GRPC REALITY",
            "listen": "127.0.0.1",
            "port": 2053,
            "protocol": "vless",
            "settings": {"clients": [], "decryption": "none"},
            "streamSettings": {
                "network": "grpc", "grpcSettings": {"serviceName": "grpc-gun"}, "security": "reality",
                "realitySettings": {"show": false, "dest": "$VLESS_GRPC_DOMAIN:443", "xver": 0, "serverNames": ["$VLESS_GRPC_DOMAIN"], "privateKey": "$PRIVATE_KEY", "shortIds": ["", "$SHORT_ID"]},
                "sockopt": { "acceptProxyProtocol": true }
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
        }
    ],
    "outbounds": [{"protocol": "freedom", "tag": "DIRECT"}, {"protocol": "blackhole", "tag": "BLOCK"}]
}
EOF
echo -e "${GREEN}✅ Конфигурация Xray создана.${NC}"

# 12. Перезапуск Marzban
echo -e "${GREEN}▶️ Перезапуск Marzban для применения всех настроек...${NC}"
marzban restart

# 13. Настройка NGINX
echo -e "${GREEN}▶️ Настройка Nginx как единого входа...${NC}"
cat << EOF > /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events { worker_connections 768; }

stream {
    map \$ssl_preread_server_name \$backend_server {
        $PANEL_DOMAIN       panel_handler;
        $VLESS_TCP_DOMAIN   marzban_vless_tcp;
        $VLESS_GRPC_DOMAIN  marzban_vless_grpc;
    }

    upstream panel_handler { server 127.0.0.1:4430; }
    upstream marzban_vless_tcp { server 127.0.0.1:8444; }
    upstream marzban_vless_grpc { server 127.0.0.1:2053; }

    server {
        listen 443;
        listen [::]:443;
        ssl_preread on;
        proxy_pass \$backend_server;
        proxy_protocol on;
    }
}

http {
    sendfile on; tcp_nopush on; types_hash_max_size 2048;
    include /etc/nginx/mime.types; default_type application/octet-stream;
    ssl_protocols TLSv1.2 TLSv1.3; ssl_prefer_server_ciphers on;
    access_log /var/log/nginx/access.log; gzip on;
    include /etc/nginx/sites-enabled/*;
}
EOF
cat << EOF > /etc/nginx/sites-available/marzban_panel.conf
server {
    listen 127.0.0.1:4430 ssl proxy_protocol;
    server_name $PANEL_DOMAIN;
    ssl_certificate /var/lib/marzban/certs/fullchain.pem;
    ssl_certificate_key /var/lib/marzban/certs/key.pem;
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -s /etc/nginx/sites-available/marzban_panel.conf /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx && systemctl enable nginx
echo -e "${GREEN}✅ Nginx настроен.${NC}"

# 14. Настройка UFW (минималистичная и безопасная)
echo -e "${GREEN}▶️ Настройка файрвола UFW...${NC}"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 443/tcp comment 'Nginx HTTPS/VLESS'
ufw --force enable
echo -e "${GREEN}✅ UFW настроен и активирован.${NC}"

# 15. Установка Fail2Ban с эшелонированной защитой
echo -e "${GREEN}▶️ Установка и настройка Fail2Ban...${NC}"
cat << EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = iptables-allports
bantime = 1w
findtime = 1d
maxretry = 5
EOF
systemctl restart fail2ban && systemctl enable fail2ban
echo -e "${GREEN}✅ Fail2Ban установлен и настроен для защиты SSH.${NC}"

# 16. НАСТРОЙКА БЭКАПОВ
(Вставьте ваш блок настройки бэкапов сюда, если он нужен. Он не конфликтует)

# 17. Финальная проверка и информация
echo -e "\n${GREEN}✅✅✅ Установка и настройка Marzban + Nginx завершены! ✅✅✅${NC}"
echo -e "------------------------------------------------------------------"
echo -e "Панель Marzban доступна по адресу: ${YELLOW}https://$PANEL_DOMAIN${NC}"
echo -e "Используйте команду ${YELLOW}marzban status${NC} для проверки состояния."
echo -e "Используйте команду ${YELLOW}ufw status${NC} для проверки файрвола."
echo -e "Используйте ${YELLOW}sudo fail2ban-client status sshd${NC} для проверки банов."
echo -e "\n${YELLOW}ВАЖНО: Для генерации правильных клиентских ссылок, в панели Marzban"
echo -e "в настройках инбаундов VLESS вручную укажите:${NC}"
echo -e " - ${GREEN}Для VLESS TCP:${NC}  Хост: ${YELLOW}$PANEL_DOMAIN:443${NC}, SNI: ${YELLOW}$VLESS_TCP_DOMAIN${NC}"
echo -e " - ${GREEN}Для VLESS GRPC:${NC} Хост: ${YELLOW}$PANEL_DOMAIN:443${NC}, SNI: ${YELLOW}$VLESS_GRPC_DOMAIN${NC}"
echo -e "------------------------------------------------------------------"