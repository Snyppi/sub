#!/bin/bash

# --- Цвета и проверка root ---
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
if [ "$EUID" -ne 0 ]; then echo -e "${RED}❌ Запустите от имени root${NC}"; exit 1; fi

# --- Запрос данных (с локацией) ---
echo -e "${GREEN}Введите домен для панели Marzban:${NC}"; read -r PANEL_DOMAIN
if [ -z "$PANEL_DOMAIN" ]; then echo -e "${RED}❌ Домен обязателен${NC}"; exit 1; fi
echo -e "${GREEN}Введите домен для маскировки VLESS TCP:${NC}"; read -r VLESS_TCP_DOMAIN
if [ -z "$VLESS_TCP_DOMAIN" ]; then echo -e "${RED}❌ Домен обязателен${NC}"; exit 1; fi
echo -e "${GREEN}Введите домен для маскировки VLESS GRPC:${NC}"; read -r VLESS_GRPC_DOMAIN
if [ -z "$VLESS_GRPC_DOMAIN" ]; then echo -e "${RED}❌ Домен обязателен${NC}"; exit 1; fi
LOCATION_STRING=""
while [ -z "$LOCATION_STRING" ]; do
    echo -e "\n${GREEN}Выберите локацию:${NC}"
    echo "1) US 🇺🇸"; echo "2) DE 🇩🇪"; echo "3) NL 🇳🇱"; echo "4) FI 🇫🇮"; echo "5) RU 🇷🇺"; echo "6) SE 🇸🇪"
    read -p "Номер (1-6): " choice
    case $choice in
        1) LOCATION_STRING="SnyppiVPN🇺🇸";; 2) LOCATION_STRING="SnyppiVPN🇩🇪";;
        3) LOCATION_STRING="SnyppiVPN🇳🇱";; 4) LOCATION_STRING="SnyppiVPN🇫🇮";;
        5) LOCATION_STRING="SnyppiVPN🇷🇺";; 6) LOCATION_STRING="SnyppiVPN🇸🇪";;
        *) echo -e "${RED}Неверный выбор.${NC}"; continue ;;
    esac
    break
done

# --- ШАГ 1: УСТАНОВКА ЗАВИСИМОСТЕЙ ---
echo -e "${GREEN}▶️ Установка зависимостей...${NC}"
apt update && apt install -y curl socat git docker.io docker-compose nginx-full ufw fail2ban

# --- ШАГ 2: УСТАНОВКА MARZBAN (ВАШ РАБОЧИЙ МЕТОД) ---
echo -e "${GREEN}▶️ Установка Marzban...${NC}"
bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install
echo -e "${YELLOW}ℹ️ ЕСЛИ СКРИПТ ОСТАНОВИЛСЯ НА ПОКАЗЕ ЛОГОВ, ПОДОЖДИТЕ 10 СЕКУНД И НАЖМИТЕ CTRL+C, ЧТОБЫ ПРОДОЛЖИТЬ!${NC}"
sleep 5 

# --- ШАГ 3: ПОЛУЧЕНИЕ СЕРТИФИКАТОВ ---
echo -e "${GREEN}▶️ Получение сертификатов...${NC}"
systemctl stop nginx
mkdir -p /var/lib/marzban/certs
if [ ! -f ~/.acme.sh/acme.sh ]; then curl https://get.acme.sh | sh -s email=snyppi@ya.ru; fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --issue --standalone --force -d "$PANEL_DOMAIN" \
  --key-file /var/lib/marzban/certs/key.pem \
  --fullchain-file /var/lib/marzban/certs/fullchain.pem
if [ ! -s "/var/lib/marzban/certs/fullchain.pem" ]; then echo -e "${RED}❌ Не удалось получить сертификаты.${NC}"; exit 1; fi

# --- ШАГ 4: НАСТРОЙКА MARZBAN ДЛЯ РАБОТЫ ЗА NGINX ---
echo -e "${GREEN}▶️ Настройка Marzban для работы за Nginx...${NC}"
cat << EOF > /opt/marzban/.env
UVICORN_HOST=0.0.0.0
UVICORN_PORT=8000
XRAY_JSON=/var/lib/marzban/xray_config.json
XRAY_SUBSCRIPTION_URL_PREFIX=https://$PANEL_DOMAIN
CUSTOM_TEMPLATES_DIRECTORY=/var/lib/marzban/templates/
SUBSCRIPTION_PAGE_TEMPLATE=subscription/index.html
SUB_PROFILE_TITLE=SnyppiVPN
SQLALCHEMY_DATABASE_URL=sqlite:////var/lib/marzban/db.sqlite3
EOF
mkdir -p /var/lib/marzban/templates/subscription
wget -N -P /var/lib/marzban/templates/subscription/ https://raw.githubusercontent.com/Snyppi/sub/main/index.html
sed -i "s|SnyppiVPN🇩🇪|$LOCATION_STRING|g" "/var/lib/marzban/templates/subscription/index.html"

# --- ШАГ 5: СОЗДАНИЕ АДМИНА И НАСТРОЙКА XRAY ---
echo -e "${GREEN}▶️ Создание админа и настройка Xray...${NC}"
# --- ИСПОЛЬЗУЕМ ПРАВИЛЬНОЕ ИМЯ КОНТЕЙНЕРА ---
printf '\n\n' | docker exec -i marzban-marzban-1 marzban-cli admin create --sudo --username snyppi --password BvbTUfzc
PRIVATE_KEY=$(docker exec marzban-marzban-1 xray x25519 | grep "Private key" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)
cat << EOF > /var/lib/marzban/xray_config.json
{"log":{"loglevel":"info"},"inbounds":[{"tag":"VLESS TCP REALITY","listen":"127.0.0.1","port":8444,"protocol":"vless","settings":{"clients":[],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"$VLESS_TCP_DOMAIN:443","xver":0,"serverNames":["$VLESS_TCP_DOMAIN"],"privateKey":"$PRIVATE_KEY","shortIds":["$SHORT_ID"]},"sockopt":{"acceptProxyProtocol":true}},"sniffing":{"enabled":true,"destOverride":["http","tls"]}},{"tag":"VLESS GRPC REALITY","listen":"127.0.0.1","port":2053,"protocol":"vless","settings":{"clients":[],"decryption":"none"},"streamSettings":{"network":"grpc","grpcSettings":{"serviceName":"grpc-gun"},"security":"reality","realitySettings":{"show":false,"dest":"$VLESS_GRPC_DOMAIN:443","xver":0,"serverNames":["$VLESS_GRPC_DOMAIN"],"privateKey":"$PRIVATE_KEY","shortIds":["","$SHORT_ID"]},"sockopt":{"acceptProxyProtocol":true}},"sniffing":{"enabled":true,"destOverride":["http","tls"]}}],"outbounds":[{"protocol":"freedom","tag":"DIRECT"},{"protocol":"blackhole","tag":"BLOCK"}]}
EOF
marzban restart

# --- ШАГ 6: НАСТРОЙКА NGINX И ОСТАЛЬНОГО ---
echo -e "${GREEN}▶️ Настройка Nginx, UFW, Fail2Ban...${NC}"
cat << EOF > /etc/nginx/nginx.conf
user www-data; worker_processes auto; pid /run/nginx.pid; include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 768; }
stream {
    map \$ssl_preread_server_name \$backend_server { $PANEL_DOMAIN panel_handler; default marzban_vless_tcp; }
    upstream panel_handler { server 127.0.0.1:4430; }
    upstream marzban_vless_tcp { server 127.0.0.1:8444; }
    server { listen 443; listen [::]:443; ssl_preread on; proxy_pass \$backend_server; proxy_protocol on; }
}
http {
    sendfile on; tcp_nopush on; types_hash_max_size 2048; include /etc/nginx/mime.types; default_type application/octet-stream;
    ssl_protocols TLSv1.2 TLSv1.3; ssl_prefer_server_ciphers on; access_log /var/log/nginx/access.log; gzip on;
    server {
        listen 127.0.0.1:4430 ssl http2 proxy_protocol;
        server_name $PANEL_DOMAIN;
        ssl_certificate /var/lib/marzban/certs/fullchain.pem; ssl_certificate_key /var/lib/marzban/certs/key.pem;
        real_ip_header proxy_protocol; set_real_ip_from 127.0.0.1;
        location / {
            proxy_pass http://127.0.0.1:8000;
            proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme;
        }
        location /grpc-gun {
            if (\$content_type != "application/grpc") { return 404; }
            grpc_pass grpc://127.0.0.1:2053;
        }
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx && systemctl enable nginx
ufw default deny incoming; ufw default allow outgoing; ufw allow 22/tcp; ufw allow 443/tcp; ufw --force enable
cat << EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime=1h; findtime=10m; maxretry=5
[sshd]
enabled=true
[recidive]
enabled=true; logpath=/var/log/fail2ban.log; banaction=iptables-allports; bantime=1w; findtime=1d; maxretry=5
EOF
systemctl restart fail2ban && systemctl enable fail2ban

# --- ФИНАЛ ---
echo -e "\n${GREEN}✅✅✅ Установка завершена! ✅✅✅${NC}"
echo -e "Панель: ${YELLOW}https://$PANEL_DOMAIN${NC}"
echo -e "Логин: ${YELLOW}snyppi${NC} | Пароль: ${YELLOW}BvbTUfzc${NC}"
