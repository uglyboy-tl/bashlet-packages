#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="Monitor"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

import core/log
import core/args
import core/report
import std/markdown
import std/system
import std/system

DEFAULT_OUTPUT_DIR="logs"
OUTPUT_DIR=""
FORCE_RUN=false
MAX_AGE_HOURS=24

declare -gA monitor_checks=()
declare -gA monitor_cache=()

monitor.cache() {
  local name="$1"
  local cmd="$2"
  local result
  result=$(eval "$cmd" 2>/dev/null) || result=""
  monitor_cache["$name"]="$result"
}

monitor.status_check() {
  local value="$1"
  local expected="${2:-}"
  local alt="${3:-}"

  # 如果期望值包含正则表达式
  if [[ "$expected" =~ ^/.*/$ ]]; then
    local pattern="${expected:1:-1}"
    if [[ "$value" =~ $pattern ]]; then
      echo "✅"
      return
    fi
  elif [[ "$value" == "$expected" ]]; then
    echo "✅"
    return
  fi

  # 检查备选值
  if [[ -n "$alt" ]]; then
    if [[ "$alt" =~ ^/.*/$ ]]; then
      local pattern="${alt:1:-1}"
      if [[ "$value" =~ $pattern ]]; then
        echo "⚠️"
        return
      fi
    elif [[ "$value" == "$alt" ]]; then
      echo "⚠️"
      return
    fi
  fi

  echo "❌"
}

monitor.threshold() {
  local value="$1"
  local warn="${2:-}"
  local crit="${3:-}"
  [[ -z "$warn" ]] && echo "✅" && return

  local num_val=$(echo "$value" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
  [[ -z "$num_val" ]] && echo "❓" && return

  if (($(echo "$num_val > $crit" | bc -l 2>/dev/null || echo 0))); then
    echo "❌"
  elif (($(echo "$num_val > $warn" | bc -l 2>/dev/null || echo 0))); then
    echo "⚠️"
  else
    echo "✅"
  fi
}

monitor.add() {
  local name="$1"
  local cmd="$2"
  local unit="${3:-}"
  local warn="${4:-}"
  local crit="${5:-}"

  local result
  # 替换 @缓存名 为缓存的命令结果
  while [[ "$cmd" =~ @([a-zA-Z_][a-zA-Z0-9_]*) ]]; do
    local cache_name="${BASH_REMATCH[1]}"
    local cache_value="${monitor_cache[$cache_name]:-}"
    cmd="${cmd//@${cache_name}/${cache_value}}"
  done
  result=$(eval "$cmd" 2>/dev/null) || result="N/A"
  result=$(string.trim "$result")

  # 如果 unit 是特殊值 "status"，则使用状态判断
  local status
  if [[ "$unit" == "status" ]]; then
    status=$(monitor.status_check "$result" "$warn" "$crit")
  else
    status=$(monitor.threshold "$result" "$warn" "$crit")
    [[ -n "$unit" && -n "$result" && "$result" != "N/A" && "$unit" != "status" ]] && result="$result $unit"
  fi

  monitor_checks["${name}_value"]="$result"
  monitor_checks["${name}_status"]="$status"
}

monitor.display() {
  local -a check_names=()
  for key in "${!monitor_checks[@]}"; do
    [[ "$key" == *_value ]] || continue
    local name="${key%_value}"
    check_names+=("$name")
  done

  report.table.begin "检查项" "值" "状态"
  for name in "${check_names[@]}"; do
    local val="${monitor_checks[${name}_value]:-N/A}"
    local status="${monitor_checks[${name}_status]:-❓}"
    report.table.add "$name" "$val" "$status"
  done
  report.table.end
  monitor_checks=()
}

hours_since() {
  local name=$(basename "$1" .md)
  local now=$(date +"%Y%m%d_%H%M%S")

  local file_day=${name:0:8}
  local file_time=${name:9:6}
  local now_day=${now:0:8}
  local now_time=${now:9:6}

  local days=$((now_day - file_day))
  local time_val=$((10#${now_time:0:2} * 10000 + 10#${now_time:2:2} * 100 + 10#${now_time:4:2}))
  local file_val=$((10#${file_time:0:2} * 10000 + 10#${file_time:2:2} * 100 + 10#${file_time:4:2}))

  echo $((days * 24 + (time_val - file_val) / 10000))
}

check_data_freshness() {
  [[ "$FORCE_RUN" == true ]] && {
    log.info "强制重新采集数据"
    return 0
  }

  local latest_file=$(ls "$OUTPUT_DIR"/*.md 2>/dev/null | tail -1)
  [[ -z "$latest_file" ]] && {
    log.info "未找到历史记录文件"
    return 0
  }

  local age_hours=$(hours_since "$latest_file")

  if ((age_hours < MAX_AGE_HOURS)); then
    log.info "数据有效（${age_hours} 小时前）"
    echo "跳过采集（最近报告: $latest_file）"
    return 1
  fi

  log.info "数据已过期（${age_hours} 小时）"
  return 0
}

export_with_info() {
  local file=$(report.export)
  local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "未知")
  console.stdout "报告已生成: $file ($size 字节)"
}

args_common() {
  args.init

  args.add_options "verbose" "v" "详细输出模式"
  args.add_options "force" "f" "强制重新采集（忽略时效性检查）"
  args.add_options "output" "o" "指定输出目录（默认: $DEFAULT_OUTPUT_DIR）" "FILE"
  args.process "$@"

  OUTPUT_DIR=$(args.get "-o" "--output") 2>/dev/null || OUTPUT_DIR="${DEFAULT_OUTPUT_DIR}/${_ARGS_CURRENT_SUBCOMMAND}/records"
  report.dir.set "$OUTPUT_DIR"
  args.has "-v" "--verbose" && log.setLevel info || log.setLevel warn
  args.has "-f" "--force" && FORCE_RUN=true

  check_data_freshness || return 1
}

cmd_system() {
  args_common "$@" || return 0

  report.init "系统健康报告"

# 1. CPU硬件信息
  report.section "CPU硬件信息"
  monitor.cache lscpu "lscpu"
  monitor.add "CPU架构" "echo '@lscpu' | grep 'Architecture' | awk -F': ' '{print \$2}' | tr -s ' '"
  monitor.add "CPU型号" "echo '@lscpu' | grep 'Model name' | awk -F': ' '{print \$2}' | tr -s ' '"
  monitor.add "CPU核心数" "nproc"
  monitor.add "CPU当前频率" "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null | awk '{printf \"%.0f MHz\", \$1/1000}' || vcgencmd measure_clock arm 2>/dev/null | awk -F= '{printf \"%.0f MHz\", \$2/1000000}'"
  monitor.add "CPU最大频率" "echo '@lscpu' | grep 'CPU max MHz' | awk -F': ' '{print \$2}'" "MHz"
  monitor.add "CPU最小频率" "echo '@lscpu' | grep 'CPU min MHz' | awk -F': ' '{print \$2}'" "MHz"
  monitor.display

  # 2. 温度与电压
  report.section "温度与电压"
  monitor.add "CPU温度" "vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9]+\\.?[0-9]*'" "°C" 70 85
  monitor.add "核心电压" "vcgencmd measure_volts core 2>/dev/null | grep -oE '[0-9]+\\.[0-9]+'"
  monitor.add "ARM时钟" "vcgencmd measure_clock arm 2>/dev/null | awk -F= '{printf \"%.0f MHz\", \$2/1000000}'"
  monitor.display

  # 3. 内存状态
  report.section "内存状态"
  monitor.cache free_info "free -m"
  monitor.add "内存总量" "echo '@free_info' | awk '/^Mem:|^内存/{print \$2}'" "MB"
  monitor.add "已用内存" "echo '@free_info' | awk '/^Mem:|^内存/{print \$3}'" "MB"
  monitor.add "内存使用率" "free | awk '/^Mem:|^内存/{printf \"%.1f\", \$3/\$2*100}'" "%" 85 95
  monitor.add "交换空间总量" "echo '@free_info' | awk '/^Swap:|^交换/{print \$2}'" "MB"
  monitor.add "交换空间使用" "echo '@free_info' | awk '/^Swap:|^交换/{print \$3}'" "MB"
  monitor.display

  # 4. 系统负载
  report.section "系统负载"
  monitor.cache loadavg "cat /proc/loadavg"
  monitor.add "负载(1m)" "echo '@loadavg' | awk '{print \$1}'" "" 2.0 4.0
  monitor.add "负载(5m)" "echo '@loadavg' | awk '{print \$2}'" "" 2.0 4.0
  monitor.add "负载(15m)" "echo '@loadavg' | awk '{print \$3}'" "" 2.0 4.0
  monitor.add "每核心负载" "cores=\$(nproc 2>/dev/null || echo 1); load1=\$(echo '@loadavg' | awk '{print \$1}'); awk -v load=\"\$load1\" -v cores=\"\$cores\" 'BEGIN { printf \"%.2f\", load/cores }'" "" 2.0 4.0
  monitor.display

  # 5. 硬件设备信息
  report.section "硬件设备信息"
  report.subsection "系统信息"
  report.code "uname -a"

  report.subsection "树莓派型号"
  report.code "cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || echo '非树莓派设备'"

  report.subsection "PCI设备"
  report.code "lspci 2>/dev/null | head -10 || echo '无PCI设备'"

  report.subsection "USB设备"
  report.code "lsusb 2>/dev/null | head -10 || echo '无USB设备'"

  # 6. 系统日志硬件错误
  report.section "系统日志硬件错误"
  report.subsection "dmesg错误（最近10条）"
  report.code "dmesg -T --level=err 2>/dev/null | grep -i 'cpu\|memory\|thermal\|voltage\|hardware' | tail -10 || echo '无硬件错误'"

  report.subsection "journalctl错误（最近1天）"
  report.code "journalctl --since='1 day ago' --priority=err 2>/dev/null | grep -i 'cpu\|memory\|thermal\|hardware.*error' | tail -10 || echo '无硬件错误'"

  # 7. 关键服务状态
  local -a services=(
    "systemd-sysctl" "systemd-timesyncd" "NetworkManager"
    "fail2ban" "smartmontools" "ssh"
    "rsyslog" "cron" "docker"
    "blk-availability" "systemd-journald" "systemd-udevd"
  )

  report.section "关键服务状态"
  for svc in "${services[@]}"; do
    monitor.add "$svc" "systemctl is-active \"$svc\" 2>/dev/null" "status" "active" "inactive"
  done
  monitor.display

  export_with_info
}

cmd_performance() {
  args_common "$@" || return 0

  report.init "性能优化报告"

# 1. 系统启动时间分析
  report.section "系统启动时间分析"

  # 基础启动时间
  report.subsection "基础启动时间"
  monitor.cache startup_info "systemd-analyze time --no-pager 2>/dev/null | head -1"
  monitor.add "内核启动时间" "echo '@startup_info' | sed -E 's/.*in ([^ ]+) \(kernel\) \+ .* /\1/'"
  monitor.add "用户空间启动时间" "echo '@startup_info' | sed -E 's/.*\+ ([^ ]+) \(userspace\) = .*/\1/'"
  monitor.add "总启动时间" "echo '@startup_info' | sed -E 's/.*= ([^ ]+) .*/\1/'"
  monitor.display

  # Docker启动信息
  report.subsection "Docker启动信息"
  monitor.cache docker_blame "systemd-analyze blame --no-pager 2>/dev/null"
  local docker_count_cmd="docker ps -q 2>/dev/null | wc -l || echo '0'"
  local docker_time_cmd="echo '@docker_blame' | awk '/docker\\.service/ {print \$1}'"
  monitor.add "Docker容器数量" "$docker_count_cmd"
  monitor.add "Docker服务启动时间" "$docker_time_cmd"
  monitor.display

  # 启动瓶颈服务
  report.subsection "启动瓶颈服务"
  monitor.add "瓶颈服务 1" "echo '@docker_blame' | awk '\$1+0 > 2 {print \$2 \" (\" \$1 \")\"}' | head -1"
  monitor.add "瓶颈服务 2" "echo '@docker_blame' | awk '\$1+0 > 2 {print \$2 \" (\" \$1 \")\"}' | head -2 | tail -1"
  monitor.add "瓶颈服务 3" "echo '@docker_blame' | awk '\$1+0 > 2 {print \$2 \" (\" \$1 \")\"}' | head -3 | tail -1"
  monitor.display

  # 2. 高资源进程分析
  report.section "高资源进程分析"

  report.subsection "CPU占用Top5"
  report.code "ps aux --sort=-%cpu 2>/dev/null | head -6 | awk 'NR==1 {printf \"%-10s %6s %6s %6s %s\\n\", \"USER\", \"PID\", \"CPU%\", \"MEM%\", \"COMMAND\"} NR>1 {cmd=\$11; gsub(/.*\//, \"\", cmd); printf \"%-10s %6s %6s %6s %s\\n\", \$1, \$2, \$3\"%\", \$4\"%\", cmd}'"

  report.subsection "内存占用Top5"
  report.code "ps aux --sort=-%mem 2>/dev/null | head -6 | awk 'NR==1 {printf \"%-10s %6s %6s %6s %s\\n\", \"USER\", \"PID\", \"CPU%\", \"MEM%\", \"COMMAND\"} NR>1 {cmd=\$11; gsub(/.*\//, \"\", cmd); printf \"%-10s %6s %6s %6s %s\\n\", \$1, \$2, \$3\"%\", \$4\"%\", cmd}'"

  report.subsection "高资源进程"
  report.code "ps aux --sort=-%cpu 2>/dev/null | awk 'NR>1 && \$3+0 > 50 {cmd=\$11; gsub(/.*\//, \"\", cmd); print \"  \" cmd \" (\" \$3 \"%)\"}' | head -3 || echo '  无'"

  report.subsection "僵尸进程检查"
  report.code "ps aux 2>/dev/null | awk '\$8==\"Z\" {count++; print \"  PID=\" \$2 \" \" \$11} END {if(count+0==0) print \"\n  无\"; else print \"\n  共\" count \"个\"}' | head -6; echo '';"

  # 3. 最近安装的软件包
  report.section "软件包管理"
  report.subsection "最近7天安装"
  report.code "bash package.sh -d 7"

  export_with_info
}

cmd_network() {
  args_common "$@" || return 0

  report.init "网络监控报告"

  # 1. 网络接口检查
  report.section "网络接口信息"
  monitor.cache ip_link "ip -s link show eth0 2>/dev/null || ip -s link show \$(ip link show | grep -E '^[0-9]+:' | grep -v 'lo:' | head -1 | awk -F: '{print \$2}' | xargs) 2>/dev/null"
  monitor.cache ethtool "sudo ethtool eth0 2>/dev/null | grep -E 'Speed|Duplex|Link detected|Auto-negotiation' || echo ''"
  monitor.add "网卡速度" "echo '@ethtool' | grep 'Speed:' | awk '{print \$2}' || echo 'N/A'"
  monitor.add "双工模式" "echo '@ethtool' | grep 'Duplex:' | awk '{print \$2}' || echo 'N/A'"
  monitor.add "自动协商" "echo '@ethtool' | grep 'Auto-negotiation:' | awk '{print \$2}' || echo 'N/A'"
  monitor.add "连接状态" "echo '@ethtool' | grep 'Link detected:' | awk '{print \$3}'" "status" "yes" "no"
  monitor.add "RX错误" "echo '@ip_link' | awk '/RX:/ {getline; print \$3}' || echo '0'" "" 1 10
  monitor.add "TX错误" "echo '@ip_link' | awk '/TX:/ {getline; print \$3}' || echo '0'" "" 1 10
  monitor.display

  # 2. IP地址和路由
  report.section "IP地址和路由"
  monitor.cache ip_addr "ip addr show eth0 2>/dev/null | grep 'inet ' || ip addr show | grep -A2 -E '^[0-9]+: (eth|enp|wlan)' | grep 'inet '"
  monitor.add "IP地址" "echo '@ip_addr' | awk '{print \$2}' | head -1"
  monitor.add "默认网关" "ip route 2>/dev/null | grep default | awk '{print \$3}' | head -1"
  monitor.add "Docker网络数" "docker network ls 2>/dev/null | grep -c bridge || echo '0'"
  monitor.display

  # 3. DNS检查
  report.section "DNS配置"
  monitor.cache dns_conf "cat /etc/resolv.conf 2>/dev/null"
  monitor.add "主DNS" "echo '@dns_conf' | grep nameserver | head -1 | awk '{print \$2}'"
  monitor.add "DNS服务器数" "echo '@dns_conf' | grep -c nameserver || echo '0'"
  monitor.add "百度解析" "ping -c 1 -W 1 baidu.com 2>/dev/null | grep -o 'time=[0-9.]*' | cut -d= -f2 || echo '失败'" "ms" 100 500
  monitor.add "GitHub解析" "ping -c 1 -W 1 github.com 2>/dev/null | grep -o 'time=[0-9.]*' | cut -d= -f2 || echo '失败'" "ms" 100 500
  monitor.display

  report.subsection "DNS配置文件"
  report.code "cat /etc/resolv.conf 2>/dev/null"




  # 4. 网络连接检查
  report.section "网络连接统计"
  monitor.cache ss_total "ss -s 2>/dev/null"
  monitor.add "总连接数" "echo '@ss_total' | grep 'Total:' | awk '{print \$2}'"
  monitor.add "TCP连接" "echo '@ss_total' | grep 'TCP:' | awk '{print \$2}'"
  monitor.add "UDP连接" "echo '@ss_total' | grep 'UDP:' | awk '{print \$2}'"
  monitor.add "监听端口" "ss -tuln 2>/dev/null | grep LISTEN | wc -l"
  monitor.display


  report.subsection "监听端口列表"
  report.code "ss -tuln | awk 'NR>1 && \$5~/:[0-9]+$/ {split(\$5, a, \":\"); p=a[length(a)]; if(\$1==\"tcp\") t[p]=1; else if(\$1==\"udp\") u[p]=1} END {printf \"TCP: \"; for(i in t) printf \"%s \", i; print \"\"; printf \"UDP: \"; for(i in u) printf \"%s \", i; print \"\"}'"

  # 5. 网络连通性测试
  report.section "网络连通性测试"
  monitor.cache gateway_ip "ip route 2>/dev/null | grep default | awk '{print \$3}' | head -1"
  monitor.cache dns_ip "cat /etc/resolv.conf 2>/dev/null | grep nameserver | head -1 | awk '{print \$2}'"
  monitor.add "网关IP" "echo '@gateway_ip'"
  monitor.add "网关延迟" "ping -c 1 -W 2 192.168.0.1 2>/dev/null | grep -o 'time=[0-9.]*' | cut -d= -f2 || echo '失败'" "ms" 5 20
  monitor.add "DNS服务器" "echo '@dns_ip'"
  monitor.add "DNS延迟" "ping -c 1 -W 2 192.168.0.100 2>/dev/null | grep -o 'time=[0-9.]*' | cut -d= -f2 || echo '失败'" "ms" 5 20
  monitor.display

  # 6. 网络错误日志检查
  report.section "网络错误日志检查"

  report.subsection "网络错误日志(最近5小时)"
  report.code "sudo journalctl --since '5 hour ago' 2>/dev/null | grep -i 'network\\|eth0\\|dhcp\\|dns' | grep -i 'error\\|fail\\|warn' | tail -5 || echo '未找到相关错误日志'"

  # 7. sysctl网络配置
  report.section "sysctl网络配置状态"
  report.subsection "关键网络参数"
  report.code "for param in net.core.rmem_max net.core.wmem_max net.ipv4.tcp_low_latency net.ipv4.tcp_congestion_control net.ipv4.tcp_tw_reuse; do value=\$(sudo sysctl -n \"\$param\" 2>/dev/null || echo '未知'); echo \"  \$param = \$value\"; done"
  # 8. 防火墙和Fail2Ban
  report.section "防火墙与安全防护"
  monitor.cache ufw_status "sudo ufw status verbose 2>/dev/null | head -5"
  monitor.cache f2b_status "sudo fail2ban-client status sshd 2>/dev/null || echo ''"
  monitor.add "UFW状态" "echo '@ufw_status' | grep '^Status:' | awk '{print \$2}'" "status" "active" "inactive"
  monitor.add "开放端口数" "sudo ufw status 2>/dev/null | grep -E '^[0-9]+/(tcp|udp)' | wc -l || echo '0'"
  monitor.add "Fail2Ban监狱" "sudo fail2ban-client status 2>/dev/null | grep 'Number of jail:' | awk '{print \$4}' || echo '0'"
  monitor.add "SSH攻击次数" "journalctl --since 'today' 2>/dev/null | grep -E 'Failed password|Invalid user|authentication failure' | wc -l"
  monitor.add "当前封禁IP" "echo '@f2b_status' | grep 'Currently banned:' | awk '{print \$4}' || echo '0'" "" 1 10
  monitor.display

  report.subsection "Fail2Ban详细状态"
  report.code "sudo fail2ban-client status sshd 2>/dev/null || echo 'fail2ban 未安装'"

  report.subsection "SSH攻击日志(今日)"
  report.code "echo '攻击者尝试的用户名(前5个):'; journalctl --since 'today' 2>/dev/null | grep -E 'Failed password for|Invalid user' | awk -F'for|user' '{print \$2}' | awk '{print \$1}' | sort | uniq -c | sort -rn | head -5 || echo '  无数据'"

  report.subsection "UFW防火墙规则"
  report.code "sudo ufw status verbose 2>/dev/null || echo 'ufw状态检查失败'"

  export_with_info
}

cmd_storage() {
  local -A device_type=()
  args_common "$@" || return 0

  report.init "存储监控报告"

  # 1. 存储设备概览
  report.section "存储设备概览"
  report.code "lsblk -d -o NAME,SIZE,MODEL 2>/dev/null"

  # 获取实际存储设备列表 - 简化逻辑
  local -a devices=($(lsblk -d -n -o NAME 2>/dev/null | grep -E '^sd[a-z]|^nvme' | sort -u))

  # 2. 磁盘使用情况 - 保持动态展示
  report.section "磁盘使用情况"
  report.code "df -h 2>/dev/null | grep -E '^/dev/' | awk 'NR==1 {printf \"%-20s %-10s %-10s %-10s %-6s %s\n\", \"文件系统\", \"容量\", \"已用\", \"可用\", \"使用率\", \"挂载点\"} NR>1 {printf \"%-20s %-10s %-10s %-10s %-6s %s\n\", \$1, \$2, \$3, \$4, \$5, \$6}'"

  # 如果没有检测到设备，给出提示并提前返回
  if [[ ${#devices[@]} -eq 0 ]]; then
    report.section "设备检测"
    report.code "echo '未检测到标准存储设备(sd/nvme)'"
    export_with_info
    return 0
  fi

  monitor.cache iostat_output "iostat -x 1 1 2>/dev/null"

  # 3. 按设备详细信息统计
  report.section "设备基本信息"
  for device in "${devices[@]}"; do
    report.subsection "/dev/$device"

    # 基本信息
    monitor.add "型号" "lsblk -d -n -o MODEL /dev/$device 2>/dev/null | xargs || echo '未知'"
    monitor.add "序列号" "lsblk -d -n -o SERIAL /dev/$device 2>/dev/null | xargs || echo '未知'"
    monitor.add "挂载点" "lsblk -o MOUNTPOINT /dev/$device 2>/dev/null | grep -v 'MOUNTPOINT' | grep -v '^$' | grep -v '-' | sort -u | tr '\n' ',' | sed 's/,$//' || echo '未挂载'"

    # SSD/HDD 识别
    local device_type["$device"]="Unknown"
    local rotation_info
    rotation_info=$(sudo smartctl -i /dev/$device 2>/dev/null | grep -i "Rotation Rate:" | awk '{print $3}' || echo "")
    if [[ "$rotation_info" == "Solid" ]]; then
      device_type["$device"]="SSD"
    elif [[ -n "$rotation_info" && "$rotation_info" =~ ^[0-9]+$ ]]; then
      device_type["$device"]="HDD"
    else
      local rota_value
      rota_value=$(lsblk -d -n -o ROTA /dev/$device 2>/dev/null | head -1)
      if [[ "$rota_value" == "0" ]]; then
        device_type["$device"]="SSD"
      elif [[ "$rota_value" == "1" ]]; then
        device_type["$device"]="HDD"
      fi
    fi
    monitor.add "设备类型" "echo '${device_type["$device"]}'"

    # 电源管理
    monitor.add "电源管理" "power_state=\$(sudo sdparm --page=po /dev/$device 2>/dev/null | grep -E 'STANDBY_Z' | head -1 | awk '{print \$2}' || echo 'N/A'); if [ \"\$power_state\" = \"0\" ]; then echo '禁用自动待机'; elif [ \"\$power_state\" = \"1\" ]; then echo '启用自动待机'; else echo '未知状态(\$power_state)'; fi"

    # SMART健康状态
    monitor.add "健康状态" "sudo smartctl -H /dev/$device 2>/dev/null | grep -E 'SMART overall-health|test result' | awk -F': ' '{print \$2}' || echo '检查失败'" "status" "PASSED" "FAILED"
    monitor.display
  done

  # 4. 设备性能信息
  report.section "设备性能信息"
  for device in "${devices[@]}"; do
    report.subsection "/dev/$device"
    monitor.cache smartctl_output "sudo smartctl -a /dev/$device 2>/dev/null"

    # 通用SMART指标（所有设备都支持）
    monitor.add "SMART-通电时间" "echo '@smartctl_output' | grep -i 'Power_On_Hours' | awk '{print \$NF}' || echo 'N/A'" "小时"
    monitor.add "SMART-启停次数" "echo '@smartctl_output' | grep -i 'Power_Cycle_Count' | awk '{print \$NF}' || echo 'N/A'"

    # 通用错误相关指标
    monitor.add "SMART-传输错误" "echo '@smartctl_output' | grep -i 'UDMA_CRC_Error_Count' | awk '{print \$NF}' || echo 'N/A'" "" 0 10

    # SSD特定指标
    if [[ "${device_type["$device"]}" == "SSD" ]]; then
      monitor.add "SMART-总写入量" "echo '@smartctl_output' | grep -i 'Total_LBAs_Written' | awk '{print \$NF}' || echo 'N/A'"
      monitor.add "SMART-剩余寿命" "echo '@smartctl_output' | grep -iE 'Percent_Lifetime_Remain|Percentage_Lifetime_Left|Remaining_Lifetime|Wear_Leveling_Count' | awk '{print \$NF}' | head -1 || echo 'N/A'" "%" 20 10
      monitor.add "SMART-温度" "echo '@smartctl_output' | grep -i 'Temperature_Celsius' | awk '{print \$(NF-2)}' || echo 'N/A'" "°C" 45 60
    elif [[ "${device_type["$device"]}" == "HDD" ]]; then
      monitor.add "SMART-装载次数" "echo '@smartctl_output' | grep -iE 'Load_Cycle_Count|Load_Cycle|Load.*Count' | awk '{print \$NF}' || echo 'N/A'"
      monitor.add "SMART-温度" "echo '@smartctl_output' | grep -i 'Temperature_Celsius' | awk '{print \$NF}' || echo 'N/A'" "°C" 45 60
    fi

    # I/O性能统计
    monitor.add "读取速度" "echo '@iostat_output' | tail -n +7 | grep \"^$device \" | awk '{print \$3}'" "KB/s"
    monitor.add "写入速度" "echo '@iostat_output' | tail -n +7 | grep \"^$device \" | awk '{print \$9}'" "KB/s"
    monitor.add "I/O等待" "echo '@iostat_output' | tail -n +7 | grep \"^$device \" | awk '{r=\$14; w=\$15; if(r==\"0.00\" && w==\"0.00\") print \"0.00\"; else if(r==\"0.00\") print w; else if(w==\"0.00\") print r; else printf \"%.2f\", (r+w)/2}'" "ms" 10 50

    monitor.display
  done

  # 5. 系统日志错误检查
  report.section "系统日志错误检查"

  report.subsection "内核日志(dmesg)"
  report.code "sudo dmesg 2>/dev/null | grep -i 'error\|fail\|bad\|corrupt' | grep -i 'sd[a-z]\|disk\|storage' | tail -5 || echo '未找到相关内核错误日志'"

  report.subsection "系统日志(journalctl)"
  report.code "sudo journalctl -p err,warn --since '1 day ago' 2>/dev/null | grep -iE 'sdparm|udev-worker|block device|scsi|usb.*disk|ata|disk error|io error|read error|write error|smart|mount.*fail|filesystem.*error' | grep -v 'COMMAND=' | tail -10 || echo '未找到相关存储系统错误日志'"

  export_with_info
}

main() {
  args.init

  args.add_options "version" "v" "显示版本信息"
  args.add_subcommand "storage" "监控存储信息" "cmd_storage"
  args.add_subcommand "network" "监控网络信息" "cmd_network"
  args.add_subcommand "system" "监控系统信息" "cmd_system"
  args.add_subcommand "performance" "监控性能信息" "cmd_performance"

  args.process "$@"

  args.has "-v" "--version" && usage.version && exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

