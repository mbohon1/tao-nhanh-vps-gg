#!/bin/bash
# =====================================
# Script quản lý VPS GCP thông minh (by dockaka)
# Đã cập nhật và tối ưu hóa
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

# ----- Biến cấu hình (Chung) -----
ZONE="asia-southeast1-a"
VM_NAME_BASE="vps-ubuntu-sing"
IMAGE_FAMILY="ubuntu-2204-lts"
IMAGE_PROJECT="ubuntu-os-cloud"
DISK_TYPE_DEFAULT="pd-ssd"
FIREWALL_NAME="allow-web-app"

# ----- Helpers -----

# Tìm tên instance từ TÊN, IP Ngoài hoặc IP Trong
# Tối ưu: Dùng --limit=1 thay vì | head -n1
resolve_instance_from_input() {
  local input="$1"
  local by_name
  by_name=$(gcloud compute instances list --project="$PROJECT_ID" \
    --filter="name=($input)" --format="value(name)" --limit=1)
  [[ -n "$by_name" ]] && { echo "$by_name"; return; }

  local by_ip
  by_ip=$(gcloud compute instances list --project="$PROJECT_ID" \
    --filter="EXTERNAL_IP:$input OR INTERNAL_IP:$input" \
    --format="value(name)" --limit=1)
  [[ -n "$by_ip" ]] && { echo "$by_ip"; return; }

  echo ""
}

# Lấy zone của một instance
get_zone_for_instance() {
  local name="$1"
  local zone_full
  zone_full=$(gcloud compute instances list --project="$PROJECT_ID" \
    --filter="name=($name)" --format="value(zone)" --limit=1)
  # Trích xuất phần cuối cùng của URL (tên zone)
  [[ -n "$zone_full" ]] && echo "${zone_full##*/}" || echo ""
}

# Lấy trạng thái VM (RUNNING, TERMINATED, ...)
vm_status() {
  local name="$1"
  local zone="$2"
  gcloud compute instances describe "$name" --zone="$zone" --project="$PROJECT_ID" \
    --format='get(status)' 2>/dev/null
}

# Lấy IP ngoài của VM
get_external_ip() {
  local name="$1"
  local zone="$2"
  gcloud compute instances describe "$name" --zone="$zone" --project="$PROJECT_ID" \
    --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
}

# Cài đặt firewall rule nếu chưa tồn tại
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
      --target-tags="$FIREWALL_NAME" \
      --project="$PROJECT_ID"
  fi
}

# Hàm tạo VM chính (tách riêng logic)
create_vm() {
  local MACHINE_TYPE="$1"
  local DISK_SIZE_GB="$2"
  local DISK_TYPE="${3:-$DISK_TYPE_DEFAULT}" # Dùng disk type custom hoặc mặc định

  local NAME="$VM_NAME_BASE"

  # Kiểm tra nếu tên VM đã tồn tại
  if gcloud compute instances list --project="$PROJECT_ID" --filter="name=($NAME)" --format="value(name)" --limit=1 | grep -q "^$NAME$"; then
    NAME="${VM_NAME_BASE}-$(date +%Y%m%d%H%M%S)"
    echo "⚠️ VM gốc '$VM_NAME_BASE' đã tồn tại, tạo VM mới với tên: $NAME"
  fi

  setup_firewall
  echo "👉 Đang tạo VM $NAME ($MACHINE_TYPE / ${DISK_SIZE_GB}GB / $DISK_TYPE)..."
  gcloud compute instances create "$NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --boot-disk-size="${DISK_SIZE_GB}GB" \
    --boot-disk-type="$DISK_TYPE" \
    --tags="$FIREWALL_NAME" \
    --project="$PROJECT_ID"

  if [[ $? -eq 0 ]]; then
    echo "✅ VPS đã tạo xong. SSH vào bằng:"
    echo "gcloud compute ssh $NAME --zone=$ZONE --project=$PROJECT_ID"
  else
    echo "❌ Đã xảy ra lỗi khi tạo VM."
  fi
}

# Kiểm tra port của VM
check_ports_vm() {
  read -rp "Nhập TÊN hoặc IP VM để kiểm tra port: " token
  local target
  target=$(resolve_instance_from_input "$token")
  [[ -z "$target" ]] && { echo "❌ Không tìm thấy VM."; return; } # Dùng return thay vì exit

  local zone
  zone=$(get_zone_for_instance "$target")

  echo "👉 Kiểm tra firewall rules áp dụng cho VM $target..."
  local tags
  tags=$(gcloud compute instances describe "$target" --zone="$zone" --project="$PROJECT_ID" \
    --format="get(tags.items)")

  if [[ -z "$tags" ]]; then
    echo "❌ VM $target không có network tags nào."
    return
  fi

  echo "VM $target có các tags: $tags"
  for tag in $tags; do
    echo "🔎 Firewall rule cho tag: $tag"
    gcloud compute firewall-rules list --project="$PROJECT_ID" \
      --filter="targetTags:($tag) AND direction=INGRESS AND action=ALLOW" \
      --format="table(name, allowed[].map().firewall_rule().list():label=PORT_ĐƯỢC_MỞ)"
  done
}

# Thêm port vào firewall rule mặc định
add_ports_firewall() {
  read -rp "Nhập port muốn mở thêm (vd: 8080 hoặc 8080,9000): " ports
  if [[ -z "$ports" ]]; then
    echo "❌ Không nhập port."
    return
  fi

  # Lấy danh sách port cũ
  local old_rules
  old_rules=$(gcloud compute firewall-rules describe "$FIREWALL_NAME" --project="$PROJECT_ID" \
    --format="value(allowed[0].ports)" | tr ';' ',')

  echo "👉 Đang mở thêm port: $ports (Các port cũ: $old_rules)..."
  gcloud compute firewall-rules update "$FIREWALL_NAME" \
    --allow="tcp:22,tcp:80,tcp:443,tcp:3000,tcp:5000,tcp:3100,tcp:5100,tcp:$ports,$old_rules" \
    --project="$PROJECT_ID"
  echo "✅ Đã cập nhật rule $FIREWALL_NAME"
}

# ----- Menu chính -----
# Sử dụng cat <<EOF để hiển thị menu rõ ràng hơn
cat <<EOF
=======================================
   MENU QUẢN LÝ VPS UBUNTU GCP (v2)
=======================================

--- Tạo VPS Nhanh (Ubuntu 22.04 / SSD) ---
 1) Tạo VPS (1 vCPU / 1GB RAM / 30GB SSD)  - (e2-micro)
 2) Tạo VPS (8 vCPU / 32GB RAM / 100GB SSD) - (e2-standard-8)
 3) Tạo VPS (2 vCPU / 8GB RAM / 100GB SSD)  - (e2-standard-2)
 4) Tạo VPS (4 vCPU / 16GB RAM / 100GB SSD) - (e2-standard-4)

--- Quản Lý VPS ---
 5) Liệt kê danh sách tất cả VM
 6) Dừng / Chạy lại VM (theo TÊN hoặc IP)
 7) SSH vào VM (theo TÊN hoặc IP)
 8) Xoá VM (theo TÊN hoặc IP) (CẨN THẬN!)

--- Cấu Hình Mạng ---
 9) Kiểm tra port đã mở của 1 VM
 10) Thêm port thủ công vào firewall '$FIREWALL_NAME'

 0) Thoát
=======================================
EOF

read -rp "Chọn (0-10): " choice

case "$choice" in
  # Tạo VPS
  1) create_vm "e2-micro" "30" ;;
  2) create_vm "e2-standard-8" "100" ;;
  3) create_vm "e2-standard-2" "100" ;;
  4) create_vm "e2-standard-4" "100" ;;

  # Quản lý
  5)
    echo "👉 Đang liệt kê VM trong $PROJECT_ID..."
    gcloud compute instances list --project="$PROJECT_ID"
    ;;
  6)
    read -rp "Nhập TÊN hoặc IP để Dừng/Chạy lại: " token
    target=$(resolve_instance_from_input "$token")
    [[ -z "$target" ]] && { echo "❌ Không tìm thấy VM."; exit 1; }

    zone=$(get_zone_for_instance "$target")
    status=$(vm_status "$target" "$zone")

    if [[ "$status" == "RUNNING" ]]; then
      echo "👉 VM $target đang chạy. Đang dừng lại..."
      gcloud compute instances stop "$target" --zone="$zone" --project="$PROJECT_ID" --quiet
      echo "✅ VM $target đã dừng."
    elif [[ "$status" == "TERMINATED" ]]; then
      echo "👉 VM $target đang tắt. Khởi động lại..."
      gcloud compute instances start "$target" --zone="$zone" --project="$PROJECT_ID" --quiet
      # Chờ một chút để VM lấy IP
      sleep 5
      new_ip=$(get_external_ip "$target" "$zone")
      echo "✅ VM $target đã khởi động xong."
      echo "🌐 IP mới: $new_ip"
    else
      echo "⚠️ VM $target trạng thái: $status (Không thể Dừng/Chạy)"
    fi
    ;;
  7)
    read -rp "Nhập TÊN hoặc IP để SSH: " token
    target=$(resolve_instance_from_input "$token")
    [[ -z "$target" ]] && { echo "❌ Không tìm thấy VM."; exit 1; }

    zone=$(get_zone_for_instance "$target")
    echo "👉 Đang kết nối SSH đến $target..."
    gcloud compute ssh "$target" --zone="$zone" --project="$PROJECT_ID"
    ;;
  8)
    read -rp "Nhập TÊN hoặc IP để XOÁ (CẨN THẬN!): " token
    target=$(resolve_instance_from_input "$token")
    [[ -z "$target" ]] && { echo "❌ Không tìm thấy VM."; exit 1; }

    zone=$(get_zone_for_instance "$target")
    # Thêm một bước xác nhận nữa cho an toàn
    read -rp "Bạn có CHẮC CHẮN muốn xoá vĩnh viễn VM '$target' không? (yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
      echo "👉 Đang xoá VM $target..."
      gcloud compute instances delete "$target" --zone="$zone" --project="$PROJECT_ID" --quiet
      echo "✅ Đã xoá VM $target."
    else
      echo "👍 Đã huỷ thao tác xoá."
    fi
    ;;

  # Mạng
  9) check_ports_vm ;;
  10) add_ports_firewall ;;

  # Thoát
  0)
    echo "👋 Tạm biệt!"
    ;;
  *)
    echo "❌ Lựa chọn không hợp lệ!"
    ;;
esac
