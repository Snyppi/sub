#!/usr/bin/env bash

# Установка зависимостей
install_dependencies() {
    echo "📦 Проверка и установка зависимостей..."
    for pkg in bc dnsutils whois; do
        if ! command -v "$pkg" &> /dev/null; then
            echo "⚠️ Устанавливаю $pkg..."
            sudo apt-get update && sudo apt-get install -y "$pkg"
        else
            echo "✅ $pkg уже установлен"
        fi
    done
}

# Вызов функции установки зависимостей
install_dependencies

# Файл со списком доменов (по одному на строку)
INPUT_FILE="domains.txt"
OUTPUT_FILE="good_domains.txt"

# Очистить файл с результатами
> "$OUTPUT_FILE"

# --- Функции для проверки ---

# Функция обнаружения CDN
detect_cdn() {
    local domain="$1"
    local cname ip whois_info headers

    # 1. Проверка по CNAME
    cname=$(dig +short "$domain" CNAME)
    if [[ -n "$cname" ]]; then
        case "$cname" in
            *.cloudfront.net*)   echo "AWS CloudFront"; return ;;
            *.cloudflare.net*)   echo "Cloudflare"; return ;;
            *.akamaiedge.net*)   echo "Akamai"; return ;;
            *.fastly.net*)       echo "Fastly"; return ;;
            *.llnwd.net*)        echo "Limelight"; return ;;
        esac
    fi

    # 2. Проверка по WHOIS IP-адреса
    ip=$(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    if [[ -n "$ip" ]]; then
        whois_info=$(whois "$ip")
        if echo "$whois_info" | grep -iq "Amazon\|AWS"; then echo "AWS"; return; fi
        if echo "$whois_info" | grep -iq "Cloudflare"; then echo "Cloudflare"; return; fi
        if echo "$whois_info" | grep -iq "Akamai"; then echo "Akamai"; return; fi
        if echo "$whois_info" | grep -iq "Fastly"; then echo "Fastly"; return; fi
        if echo "$whois_info" | grep -iq "Google"; then echo "Google Cloud"; return; fi
        if echo "$whois_info" | grep -iq "Microsoft"; then echo "Microsoft Azure"; return; fi
    fi

    # 3. Проверка по HTTP-заголовкам
    headers=$(curl -sIL -A "Mozilla/5.0" "https://$domain" | tr -d '\r')
    if echo "$headers" | grep -iq "server: cloudflare"; then echo "Cloudflare"; return; fi
    if echo "$headers" | grep -iq "x-amz-cf-id\|x-cache:.*cloudfront"; then echo "AWS CloudFront"; return; fi
    if echo "$headers" | grep -iq "x-fastly"; then echo "Fastly"; return; fi
    if echo "$headers" | grep -iq "server: AkamaiGHost"; then echo "Akamai"; return; fi

    echo ""
}

# Функция, которая выполняет все проверки для одного домена
process_domain() {
    local domain="$1"
    echo "🔍 Проверяю: $domain"

    # Проверка на использование CDN
    local cdn_provider
    cdn_provider=$(detect_cdn "$domain")
    if [[ -n "$cdn_provider" ]]; then
        echo "❌ Обнаружен CDN ($cdn_provider): $domain"
        return
    fi

    # Пинг
    local ping_time
    ping_time=$(ping -c 1 "$domain" | grep 'time=' | sed -E 's/.*time=([0-9\.]+) ms.*/\1/')
    if [ -z "$ping_time" ]; then
        echo "❌ Нет пинга: $domain"
        return
    fi

    if (( $(echo "$ping_time > 10" | bc -l) )); then
        echo "❌ Пинг > 10ms: $domain ($ping_time ms)"
        return
    fi

    # IP-адрес
    local ip
    ip=$(dig +short "$domain" A | grep '^[0-9]' | head -n1)
    if [ -z "$ip" ]; then
        echo "❌ Не удалось получить IP: $domain"
        return
    fi

    # Проверка HTTP/2
    if ! curl -I --http2 -s -m 4 "https://$domain" 2>/dev/null | grep -q 'HTTP/2'; then
        echo "❌ Нет HTTP/2: $domain"
        return
    fi

    # Проверка TLS 1.3
    if ! echo | openssl s_client -connect "$domain:443" -servername "$domain" -tls1_3 2>/dev/null | grep -q 'TLSv1.3'; then
        echo "❌ Нет TLS 1.3: $domain"
        return
    fi

    echo "✅ OK: $domain ($ip, ${ping_time}ms)"
    echo "$domain | $ip | ${ping_time}ms" >> "$OUTPUT_FILE"
}

# Экспортируем функции и переменные, чтобы они были доступны в subshell
export -f detect_cdn
export -f process_domain
export OUTPUT_FILE

# --- Основной цикл ---
while IFS= read -r domain; do
    timeout 5s bash -c "process_domain '$domain'" || echo "⌛️ Таймаут или ошибка при проверке: $domain"
done < "$INPUT_FILE"

echo ""
echo "✅ Все проверки завершены."
echo "Список подходящих доменов сохранён в: $OUTPUT_FILE"
