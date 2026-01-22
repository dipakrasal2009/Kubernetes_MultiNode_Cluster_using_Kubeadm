#!/bin/bash
set -e

echo "=============================="
echo " Kubernetes Setup Script"
echo " Ubuntu 22.04 + kubeadm"
echo "=============================="

read -p "Enter node role (master/worker): " ROLE

if [[ "$ROLE" != "master" && "$ROLE" != "worker" ]]; then
  echo "❌ Invalid role. Use master or worker."
  exit 1
fi

read -p "Enter this node PRIVATE IP (example: 192.168.56.10): " NODE_IP

if [[ -z "$NODE_IP" ]]; then
  echo "❌ Node IP cannot be empty"
  exit 1
fi

echo "➡ Role: $ROLE"
echo "➡ Node IP: $NODE_IP"
sleep 2

# ------------------------------------
# Common setup (Master + Worker)
# ------------------------------------

echo "🔧 Updating system..."
apt update -y

echo "🔧 Disabling swap..."
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

echo "🔧 Loading kernel modules..."
modprobe overlay
modprobe br_netfilter

cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# ------------------------------------
# containerd
# ------------------------------------

echo "📦 Installing containerd..."
apt install -y containerd

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

# ------------------------------------
# Kubernetes packages
# ------------------------------------

echo "📦 Installing Kubernetes components..."

apt install -y apt-transport-https ca-certificates curl gpg
mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
| gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" \
> /etc/apt/sources.list.d/kubernetes.list

apt update -y
apt install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

# ------------------------------------
# Force kubelet to use PRIVATE IP
# ------------------------------------

mkdir -p /etc/systemd/system/kubelet.service.d

cat <<EOF >/etc/systemd/system/kubelet.service.d/20-node-ip.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--node-ip=$NODE_IP"
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl restart kubelet

# ------------------------------------
# MASTER SETUP
# ------------------------------------

if [[ "$ROLE" == "master" ]]; then
  echo "🚀 Initializing Kubernetes MASTER..."

  kubeadm init \
    --apiserver-advertise-address=$NODE_IP \
    --pod-network-cidr=192.168.0.0/16

  mkdir -p $HOME/.kube
  cp /etc/kubernetes/admin.conf $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config

  echo "🌐 Installing Calico CNI..."
  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

  echo ""
  echo "✅ MASTER READY"
  echo "👉 Run this to get join command:"
  echo "   kubeadm token create --print-join-command"
fi

# ------------------------------------
# WORKER SETUP
# ------------------------------------

if [[ "$ROLE" == "worker" ]]; then
  read -p "Enter MASTER PRIVATE IP (example: 192.168.56.10): " MASTER_IP

  if [[ -z "$MASTER_IP" ]]; then
    echo "❌ Master IP required"
    exit 1
  fi

  echo ""
  echo "⚠ Worker setup done."
  echo "👉 Now run the JOIN command from master:"
  echo "   kubeadm join $MASTER_IP:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>"
fi

echo ""
echo "🎉 Script completed successfully"

