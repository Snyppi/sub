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

# Резервное копирование
echo "Создание резервной копии /etc/sysctl.conf..."
cp /etc/sysctl.conf /etc/sysctl.conf.backup-$(date +%F)

# Установка зависимостей
echo "Установка зависимостей..."
apt update
apt install -y curl wget lsb-release ca-certificates software-properties-common apt-transport-https dkms

# Проверка инструментов мониторинга
echo "Установка iperf3, nload, htop..."
if ! command -v iperf3 >/dev/null || ! command -v nload >/dev/null || ! command -v htop >/dev/null; then
  apt install -y iperf3 nload htop
fi

# Проверка совместимости CPU
echo "Проверка совместимости CPU..."
wget -q https://dl.xanmod.org/check_x86-64_psabi.sh
chmod +x check_x86-64_psabi.sh
CPU_LEVEL=$(./check_x86-64_psabi.sh | grep "x86-64-v" | awk '{print $NF}')
if [ "$CPU_LEVEL" != "x86-64-v3" ] && [ "$CPU_LEVEL" != "x86-64-v4" ]; then
  echo "CPU не поддерживает x86-64-v3 (текущий уровень: $CPU_LEVEL). Устанавливаем linux-xanmod вместо linux-xanmod-x64v3."
  XANMOD_PKG="linux-xanmod"
else
  echo "CPU поддерживает x86-64-v3. Устанавливаем linux-xanmod-x64v3."
  XANMOD_PKG="linux-xanmod-x64v3"
fi
rm check_x86-64_psabi.sh

# Установка ядра XanMod
echo "Добавление репозитория XanMod..."
curl -fSsL https://dl.xanmod.org/gpg.key | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/xanmod-release.list
apt update
apt install -y $XANMOD_PKG
grub-mkconfig -o /boot/grub/grub.cfg

# Проверка RAM для настройки буферов
TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
if [ "$TOTAL_RAM" -lt 1024 ]; then
  echo "Обнаружено мало RAM ($TOTAL_RAM МБ). Устанавливаем буферы TCP 8 МБ."
  RWMEM_MAX=8388608
  RWMEM_DEFAULT=8388608
  TCP_RMEM="4096 87380 8388608"
  TCP_WMEM="4096 65536 8388608"
else
  echo "Обнаружено достаточно RAM ($TOTAL_RAM МБ). Устанавливаем буферы TCP 16 МБ."
  RWMEM_MAX=16777216
  RWMEM_DEFAULT=16777216
  TCP_RMEM="4096 87380 16777216"
  TCP_WMEM="4096 65536 16777216"
fi

# Настройка sysctl
echo "Настройка сетевых параметров sysctl..."
cat << EOF > /etc/sysctl.d/99-vpn-optimize.conf
# BBR congestion control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# TCP buffer sizes
net.core.rmem_max=$RWMEM_MAX
net.core.wmem_max=$RWMEM_MAX
net.core.rmem_default=$RWMEM_DEFAULT
net.core.wmem_default=$RWMEM_DEFAULT
net.ipv4.tcp_rmem=$TCP_RMEM
net.ipv4.tcp_wmem=$TCP_WMEM

# For many concurrent connections
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535

# Selective ACK
net.ipv4.tcp_sack=1
EOF

# Загрузка модуля tcp_bbr
echo "Загрузка модуля tcp_bbr..."
modprobe tcp_bbr 2>/dev/null || echo "Модуль tcp_bbr встроен в ядро или уже активен"

# Применение sysctl
sysctl -p /etc/sysctl.d/99-vpn-optimize.conf

# Проверка лимитов открытых файлов для Docker
echo "Настройка лимитов открытых файлов для Docker..."
if [ -f /etc/systemd/system/docker.service.d/override.conf ]; then
  grep LimitNOFILE /etc/systemd/system/docker.service.d/override.conf || {
    mkdir -p /etc/systemd/system/docker.service.d
    echo "[Service]" > /etc/systemd/system/docker.service.d/override.conf
    echo "LimitNOFILE=512000" >> /etc/systemd/system/docker.service.d/override.conf
    systemctl daemon-reload
    systemctl restart docker
  }
else
  mkdir -p /etc/systemd/system/docker.service.d
  echo "[Service]" > /etc/systemd/system/docker.service.d/override.conf
  echo "LimitNOFILE=512000" >> /etc/systemd/system/docker.service.d/override.conf
  systemctl daemon-reload
  systemctl restart docker
fi

# Проверка портов для Outline (8443) и Marzban (443)
echo "Проверка портов 443 и 8443..."
ss -lnptu | grep -E '443|8443' && {
  echo "Внимание: порты 443 или 8443 заняты. Убедитесь, что они свободны для Outline (8443) и Marzban (443)."
}

# Проверка состояния
echo "Проверка оптимизации..."
echo "Ядро:"
uname -r
echo "TCP алгоритм:"
sysctl net.ipv4.tcp_congestion_control
echo "Очередь пакетов:"
sysctl net.core.default_qdisc
echo "Буферы:"
sysctl net.core.rmem_max
sysctl net.core.wmem_max
echo "Лимиты соединений:"
sysctl net.core.somaxconn
sysctl net.ipv4.tcp_max_syn_backlog
echo "Порты (для Outline: 8443, Marzban: 443):"
ss -lnptu | grep -E '443|8443'
echo "MTU:"
ip link show | grep mtu | grep -v lo
echo "Лимиты открытых файлов для Docker:"
grep LimitNOFILE /etc/systemd/system/docker.service.d/override.conf || echo "Лимиты для Docker не установлены"

# Проверка производительности
echo "Тестирование сети..."
iperf3 -c iperf.he.net || echo "Тест iperf3 не удался. Убедитесь, что iperf3 установлен и сервер доступен."

echo "Оптимизация завершена! Для применения ядра требуется перезагрузка."
read -p "Перезагрузить сервер сейчас? (y/n): " REBOOT
if [ "$REBOOT" = "y" ]; then
  echo "Перезагрузка..."
  reboot
else
  echo "Перезагрузите сервер позже: sudo reboot"
fi