#!/bin/bash

DISKS_TO_MONITOR=({{ monitor.check_disks | join(' ') }})

SERVER_NAME='{{ monitor.server_name }}'
NOTIFY_SLACK_WEBHOOK='{{ monitor.notify_slack_webhook }}'
NOTIFY_SLACK_CHANNEL='{{ monitor.notify_slack_channel }}'

ALERT_THREAD_CPU_P2={{ monitor.alert_thread_cpu_p2 }}
ALERT_THREAD_CPU_P1={{ monitor.alert_thread_cpu_p1 }}
ALERT_THREAD_RAM_P2={{ monitor.alert_thread_ram_p2 }}
ALERT_THREAD_RAM_P1={{ monitor.alert_thread_ram_p1 }}
ALERT_THREAD_DISK_P2={{ monitor.alert_thread_disk_p2 }}
ALERT_THREAD_DISK_P1={{ monitor.alert_thread_disk_p1 }}

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

cpu_usage() {
  top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}' | sed 's/%//'
}

memory_usage() {
  free | grep Mem | awk '{print $3/$2 * 100.0}'
}

disk_remain() {
  for disk in "${DISKS_TO_MONITOR[@]}"; do
    remain=$(df -h | grep "^$disk" | awk '{print $4}' | sed 's/G//')
    echo "$disk $remain"
  done
}

request_count() {
  ss -s | grep 'estab' | awk '{print $2}'
}

generate_alert_message() {
  local cpu=$(cpu_usage)
  local ram=$(memory_usage)
  local tcp=$(request_count)
  local alert_message="[]"
  local priority='P2'

  if (( $(echo "$cpu > $ALERT_THREAD_CPU_P1" | bc -l) )); then
    priority='P1'
  fi
  if (( $(echo "$ram > $ALERT_THREAD_RAM_P1" | bc -l) )); then
    priority='P1'
  fi
  if [[ "P1" == "$priority" ]]; then
    priority_alert=$(jq -n --arg priority "${priority}" '[{"type":"mrkdwn","text":"*Priority*"},{"type":"plain_text","text":$priority}]')
    alert_message=$(echo "$alert_message" | jq --argjson priority_alert "$priority_alert" '. += $priority_alert')
  fi

  if (( $(echo "$cpu > $ALERT_THREAD_CPU_P2" | bc -l) )); then
    cpu_alert=$(jq -n --arg cpu "${cpu}%" '[{"type":"mrkdwn","text":"*CPU*"},{"type":"plain_text","text":$cpu}]')
    alert_message=$(echo "$alert_message" | jq --argjson cpu_alert "$cpu_alert" '. += $cpu_alert')
  fi

  if (( $(echo "$ram > $ALERT_THREAD_RAM_P2" | bc -l) )); then
    ram_alert=$(jq -n --arg ram "${ram}%" '[{"type":"mrkdwn","text":"*RAM*"},{"type":"plain_text","text":$ram}]')
    alert_message=$(echo "$alert_message" | jq --argjson ram_alert "$ram_alert" '. += $ram_alert')
  fi

  if [[ "$alert_message" != "[]" ]]; then
    tcp_alert=$(jq -n --arg tcp "${tcp}" '[{"type":"mrkdwn","text":"*TCP*"},{"type":"plain_text","text":$tcp}]')
    alert_message=$(echo "$alert_message" | jq --argjson tcp_alert "$tcp_alert" '. += $tcp_alert')
  fi

  echo "$alert_message"
}


generate_disk_alert_message() {
  local alert_message="[]"
  local priority='P2'

  while IFS= read -r line; do
    local disk=$(echo $line | awk '{print $1}')
    local remain=$(echo $line | awk '{print $2}')
    if [[ -z "$remain" ]]; then
      continue
    fi

    if (( $(echo "$remain < $ALERT_THREAD_DISK_P1" | bc -l) )); then
      priority='P1'
    fi
    if (( $(echo "$remain < $ALERT_THREAD_DISK_P2" | bc -l) )); then
      disk_alert=$(jq -n --arg disk "*DISK* ($disk)" --arg remain "${remain}G" '[{"type":"mrkdwn","text":$disk},{"type":"plain_text","text":$remain}]')
      alert_message=$(echo "$alert_message" | jq --argjson disk_alert "$disk_alert" '. += $disk_alert')
    fi
  done < <(disk_remain)

  if [[ "P1" == "$priority" ]]; then
    priority_alert=$(jq -n --arg priority "${priority}" '[{"type":"mrkdwn","text":"*Priority*"},{"type":"plain_text","text":$priority}]')
    alert_message=$(echo "$alert_message" | jq --argjson priority_alert "$priority_alert" '. += $priority_alert')
  fi

  echo "$alert_message"
}


check_and_send_alert() {
  local alert_message=$(generate_alert_message)
  local disk_alert_message=$(generate_disk_alert_message)
  local HOSTNAME=${SERVER_NAME:-$(hostname)}

  local blocks="[]"

  if [[ "$alert_message" != "[]" ]]; then
    alert_block=$(
      jq -n \
        --arg warning "[*WARNING*]: New server alert > $HOSTNAME" \
        --argjson msg "$alert_message" \
        '{ "type": "section", "text": {"type": "mrkdwn", "text": $warning}, "fields": $msg }'
    )
    blocks=$(echo "$blocks" | jq --argjson block "$alert_block" '. += [$block]')
  fi

  if [[ "$disk_alert_message" != "[]" ]]; then
    disk_block=$(
      jq -n \
        --arg warning "[*WARNING*]: New disk alert > $HOSTNAME" \
        --argjson msg "$disk_alert_message" \
        '{ "type": "section", "text": {"type": "mrkdwn", "text": $warning}, "fields": $msg }'
    )
    blocks=$(echo "$blocks" | jq --argjson block "$disk_block" '. += [$block]')
  fi

  if [[ "$blocks" != "[]" ]]; then
    local data=$(
      jq -n \
        --arg channel "$NOTIFY_SLACK_CHANNEL" \
        --argjson blocks "$blocks" \
        '{
          "username": "ServerBot",
          "icon_emoji": ":loudspeaker:",
          "channel": $channel,
          "blocks": $blocks
        }'
    )

    send_alert "$data"
  fi
}

send_alert() {
  local message=$1

  curl -X POST \
    -H "Content-type: application/json" \
    $NOTIFY_SLACK_WEBHOOK \
    --data "$message"
}

main() {
  local cpu=$(cpu_usage)
  local ram=$(memory_usage)
  local disk=$(disk_remain)
  local requests=$(request_count)
  echo "$(timestamp) CPU: ${cpu}% RAM: ${ram}% Remain Disk: ${disk}G Requests: ${requests}"

  check_and_send_alert
}

main
