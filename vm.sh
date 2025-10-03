#!/bin/bash
# =====================================
# Script quản lý VPS GCP thông minh (by dockaka)
# =====================================

# ----- Chọn project -----
echo "👉 Danh sách project bạn có:"
gcloud projects list --format="table(projectNumber, projectId, name)"

read -rp "Nhập PROJECT_ID hoặc PROJECT_NUMBER muốn dùng: " PROJECT_INPUT
if [[ -z "$PROJECT_INPUT" ]]; then
  echo "❌ Bạn chưa nhập PROJECT_ID hoặc PROJECT_NUMBER!"
  exit 1
fi

# Nếu nhập là số (PROJECT_NUMBER) -> đổi sang PROJECT_ID
if [[ "$PROJECT_INPUT" =~ ^[0-9]+$ ]]; then
  PROJECT_ID=$(gcloud projects describe "$PROJECT_INPUT" --format="value(projectId)")
else
  PROJECT_ID="$PROJECT_INPUT"
fi

gcloud config set project "$PROJECT_ID" >/dev/null
echo "✅ Đang làm việc trên project: $PROJECT_ID"

# ----- Biến cấu hình -----
ZONE="asia-southeast1-a"
VM_NAME_BASE="vps-ubuntu-sing"
DISK_SIZE="100GB"
DISK_TYPE="pd-ssd"
FIREWALL_NAME="allow-web-app"

# ----- Helpers -----
resolve_instance_from_input() {
  local input="$1"
  local by_name
  by_name=$(gcloud compute instances list --project="$PROJECT_ID" \
              --filter="name=($input)" --format="value(name)" | head -n1)
  [[ -n "$by_name" ]] && { echo "$by_name"; return; }
  local by_ip
  by_ip=$(gcloud compute instances list --project="$PROJECT_ID" \
             --filter="EXTERNAL_IP:$input OR INTERNAL_IP:$input" \
             --format="value(name)" | head -n1)
  [[ -n "$by_ip" ]] && { echo "$by_ip"; return; }
  echo ""
}

get_zone_for_instance() {
  local name="$1"
  local zone_full
  zone_full=$(gcloud compute instances list --project="$PROJECT_ID" \
               --filter="name=($name)" --format="value(zone)" | head -n1)
  [[ -n "$zone_full" ]] && echo "${zone_full##*/}" || echo ""
}

vm_status() {
  local name="$1"
  local zone="$2"
  gcloud compute instances describe "$name" --zone="$zone" --project="$PROJECT_ID" \
    --format='get(status)' 2>/dev/null
}

get_external_ip() {
  local name="$1"
  local zone="$2"
  gcloud compute instances describe "$name" --zone="$zone" --project="$PROJECT_ID" \
    --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
}

setup_firewall() {
  if ! gcloud compute firewall-rules describe "$FIREWALL_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "👉 Tạo firewall rule $FIREWALL_NAME..."
    gcloud compute firewall-rules create "$FIREWALL_NAME" \
      --direction=INGRESS \
      --priority=1000 \
      --network=default \
      --action=ALLOW \
      --rules=tcp:22,tcp:80,tcp:443,tcp:3000,tcp:5000,tcp:3100,tcp:5100 \
      --source-ranges=0.0.0.0/0 \
      --target-tags="$FIREWALL_NAME"
  fi
}

create_vm() {
  local MACHINE_TYPE="$1"
  local NAME="$VM_NAME_BASE"

  if gcloud compute instances list --project="$PROJECT_ID" --filter="name=($NAME)" --format="value(name)" | grep -q "^$NAME$"; then
    NAME="${VM_NAME_BASE}-$(date +%Y%m%d%H%M%S)"
    echo "⚠️ VM gốc đã tồn tại, tạo VM mới với tên: $NAME"
  fi

  setup_firewall
  echo "👉 Đang tạo VM $NAME ($MACHINE_TYPE) ..."
  gcloud compute instances create "$NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size="$DISK_SIZE" \
    --boot-disk-type="$DISK_TYPE" \
    --tags="$FIREWALL_NAME"

  echo "✅ VPS đã tạo xong. SSH vào bằng:"
  echo "gcloud compute ssh $NAME --zone=$ZONE --project=$PROJECT_ID"
}

check_ports_vm() {
  read -rp "Nhập TÊN hoặc IP VM để kiểm tra port: " token
  target=$(resolve_instance_from_input "$token")
  [[ -z "$target" ]] && { echo "❌ Không tìm thấy VM."; return; }
  zone=$(get_zone_for_instance "$target")

  echo "👉 Kiểm tra firewall rules áp dụng cho VM $target..."
  tags=$(gcloud compute instances describe "$target" --zone="$zone" --project="$PROJECT_ID" \
           --format="get(tags.items)")
  if [[ -z "$tags" ]]; then
    echo "❌ VM không có network tags nào."
    return
  fi

  for tag in $tags; do
    echo "🔎 Firewall rule cho tag: $tag"
    gcloud compute firewall-rules list --project="$PROJECT_ID" \
      --filter="targetTags:($tag)" \
      --format="table(name,direction,action,allowed[].map().firewall_rule().list())"
  done
}

add_ports_firewall() {
  read -rp "Nhập port muốn mở thêm (vd: 8080,9000): " ports
  if [[ -z "$ports" ]]; then
    echo "❌ Không nhập port."
    return
  fi
  echo "👉 Đang mở thêm port: $ports ..."
  gcloud compute firewall-rules update "$FIREWALL_NAME" \
    --allow="tcp:22,tcp:80,tcp:443,tcp:3000,tcp:5000,tcp:3100,tcp:5100,tcp:$ports" \
    --project="$PROJECT_ID"
  echo "✅ Đã cập nhật rule $FIREWALL_NAME"
}

# ----- Menu -----
echo "==============================="
echo " MENU QUẢN LÝ VPS UBUNTU GCP "
echo "==============================="
echo "1) Tạo VPS (2 vCPU / 8GB RAM / 100GB SSD)"
echo "2) Tạo VPS (4 vCPU / 16GB RAM / 100GB SSD)"
echo "3) Xoá VM theo TÊN hoặc IP"
echo "4) Dừng / Chạy lại VM theo TÊN hoặc IP (in IP mới)"
echo "5) Liệt kê danh sách VM trong project"
echo "6) SSH vào VM theo TÊN hoặc IP"
echo "7) Kiểm tra port đã mở của 1 VM"
echo "8) Thêm port thủ công vào firewall"
echo "==============================="
read -rp "Chọn (1-8): " choice

case "$choice" in
  1) create_vm "e2-standard-2" ;;
  2) create_vm "e2-standard-4" ;;
  3)
    read -rp "Nhập TÊN hoặc IP để xoá: " token
    target=$(resolve_instance_from_input "$token")
    [[ -z "$target" ]] && { echo "❌ Không tìm thấy VM."; exit 1; }
    zone=$(get_zone_for_instance "$target")
    gcloud compute instances delete "$target" --zone="$zone" --quiet
    ;;
  4)
    read -rp "Nhập TÊN hoặc IP để dừng/chạy lại: " token
    target=$(resolve_instance_from_input "$token")
    [[ -z "$target" ]] && { echo "❌ Không tìm thấy VM."; exit 1; }
    zone=$(get_zone_for_instance "$target")
    status=$(vm_status "$target" "$zone")
    if [[ "$status" == "RUNNING" ]]; then
      echo "👉 VM $target đang chạy. Đang dừng lại..."
      gcloud compute instances stop "$target" --zone="$zone" --project="$PROJECT_ID"
      echo "✅ VM $target đã dừng."
    elif [[ "$status" == "TERMINATED" ]]; then
      echo "👉 VM $target đang tắt. Khởi động lại..."
      gcloud compute instances start "$target" --zone="$zone" --project="$PROJECT_ID"
      new_ip=$(get_external_ip "$target" "$zone")
      echo "✅ VM $target đã khởi động xong."
      echo "🌐 IP mới: $new_ip"
    else
      echo "⚠️ VM $target trạng thái: $status"
    fi
    ;;
  5) gcloud compute instances list --project="$PROJECT_ID" ;;
  6)
    read -rp "Nhập TÊN hoặc IP để SSH: " token
    target=$(resolve_instance_from_input "$token")
    [[ -z "$target" ]] && { echo "❌ Không tìm thấy VM."; exit 1; }
    zone=$(get_zone_for_instance "$target")
    gcloud compute ssh "$target" --zone="$zone" --project="$PROJECT_ID"
    ;;
  7) check_ports_vm ;;
  8) add_ports_firewall ;;
  *) echo "❌ Lựa chọn không hợp lệ!" ;;
esac
