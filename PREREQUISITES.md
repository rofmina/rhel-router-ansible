# Prerequisites for rhel-router-ansible

This document explains the complete setup required BEFORE running the Ansible playbook.

## Understanding the Setup

This playbook configures a VM to act as a router. For this to work properly, you need:

1. **KVM/libvirt host** - Your physical or virtual machine running KVM
2. **Two virtual networks** - One for internet, one isolated for lab
3. **netserver VM** - RHEL-based VM with 2 network interfaces
4. **Client VMs** (optional) - VMs that will use netserver for routing

## Step 1: KVM/libvirt Installation

### On RHEL-based Host (RHEL, Rocky, Alma, Fedora)

```bash
# Install KVM and libvirt
sudo dnf install -y qemu-kvm libvirt virt-install virt-manager virt-viewer

# Start and enable libvirtd
sudo systemctl enable libvirtd
sudo systemctl start libvirtd

# Add your user to libvirt group
sudo usermod -aG libvirt $USER

# Log out and back in, or run:
newgrp libvirt

# Verify installation
virsh list --all
```

### On Ubuntu/Debian Host

```bash
# Install KVM and libvirt
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virt-manager

# Add your user to required groups
sudo usermod -aG libvirt $USER
sudo usermod -aG kvm $USER

# Log out and back in for group changes to take effect

# Verify installation
virsh list --all
```

### Verify KVM is Working

```bash
# Check if KVM is loaded
lsmod | grep kvm

# Should see: kvm_intel or kvm_amd

# Check virtualization support
egrep -c '(vmx|svm)' /proc/cpuinfo

# Should return a number > 0

# Check libvirtd is running
systemctl status libvirtd
```

## Step 2: Create Virtual Networks

You need TWO networks:

### A. External Network (for internet access)

Most KVM installations have this by default as the `default` network.

**Check if it exists:**
```bash
sudo virsh net-list --all
```

You should see a network named `default` (or you might use a bridge).

**If `default` network doesn't exist, create it:**
```bash
virsh net-start default
virsh net-autostart default
```

### B. Internal Network (isolated for lab)

This is the network where client VMs will connect. **This MUST be created manually.**

**Option 1: Use the setup script** (recommended):
```bash
chmod +x setup-libvirt-network.sh
sudo ./setup-libvirt-network.sh
```

**Option 2: Manual creation**:
```bash
# Create network definition
cat > /tmp/intra-net.xml <<'EOF'
<network>
  <n>intra-net</n>
  <bridge name='virbr-internal' stp='on' delay='0'/>
  <domain name='labnet'/>
</network>
EOF

# Define, start, and enable the network
sudo virsh net-define /tmp/intra-net.xml
sudo virsh net-start intra-net
sudo virsh net-autostart intra-net

# Verify
sudo virsh net-list --all
```

**Expected output:**
```
 Name       State    Autostart   Persistent
----------------------------------------------
 default    active   yes         yes
 intra-net  active   yes         yes
```

**Verify the bridge was created:**
```bash
ip link show virbr-internal
```

## Step 3: Create or Configure netserver VM

The netserver VM **MUST** have exactly **TWO network interfaces**:
- **NIC 1**: Connected to external network (default/bridge) - for internet
- **NIC 2**: Connected to internal network (intra-net) - for lab network

### Option A: Create a New netserver VM

```bash
# Download RHEL/Rocky/Alma ISO first

# Create VM with 2 NICs
virt-install \
  --name netserver \
  --memory 2048 \
  --vcpus 2 \
  --disk size=20 \
  --cdrom /path/to/your-rhel.iso \
  --network network=default \
  --network network=intra-net \
  --graphics vnc \
  --os-variant rhel9.0

# This will open a VNC window for installation
# Complete the RHEL installation normally
```

### Option B: Add Second NIC to Existing VM

If you already have a netserver VM:

```bash
# Shutdown the VM
sudo virsh shutdown netserver

# Wait for shutdown
sudo virsh domstate netserver

# Attach second NIC to intra-net
sudo virsh attach-interface netserver network intra-net \
    --model virtio --config --persistent

# Start the VM
sudo virsh start netserver

# Verify it has 2 NICs
sudo virsh domiflist netserver
```

**Expected output:**
```
Interface   Type      Source      Model    MAC
---------------------------------------------------------------
vnet0       network   default     virtio   52:54:00:xx:xx:xx
vnet1       network   intra-net   virtio   52:54:00:yy:yy:yy
```

### Important: Interface Count

The playbook checks for **exactly 3 interfaces**:
1. `lo` (loopback) - always present
2. External NIC - connected to default/bridge
3. Internal NIC - connected to intra-net

**Verify inside netserver:**
```bash
# SSH into netserver
ssh user@netserver-ip

# Check interfaces
ip link show

# Should see 3 interfaces: lo, eth0/ens3 (or similar), eth1/ens8 (or similar)
```

## Step 4: Install Ansible on netserver

SSH into the netserver VM and install Ansible:

```bash
# On RHEL/Rocky/Alma
sudo dnf install -y git ansible-core rhel-system-roles

# Verify installation
ansible --version
```

## Step 5: Verify Prerequisites

Before running the playbook, verify everything is set up:

### On KVM Host:

```bash
# Check networks
sudo virsh net-list --all

# Should show:
# - default (active)
# - intra-net (active)

# Check netserver NICs
sudo virsh domiflist netserver

# Should show:
# - One interface on 'default' or bridge
# - One interface on 'intra-net'

# Check netserver is running
sudo virsh list --all
```

### Inside netserver:

```bash
# SSH into netserver
ssh user@netserver-ip

# Check interface count
ip link show | grep -E "^[0-9]+:" | wc -l

# Should return: 3 (lo + 2 NICs)

# Check which interface has IP (external)
ip -br addr show

# Should show:
# lo: 127.0.0.1
# eth0/ens3: IP from DHCP (e.g., 192.168.122.x)
# eth1/ens8: NO IP (this will become internal 10.0.1.1)

# Verify internet connectivity
ping -c 4 8.8.8.8

# Check Ansible is installed
ansible --version
```

## Common Issues and Solutions

### Issue: "default network not found"

**Solution:**
```bash
# Start the default network
sudo virsh net-start default
sudo virsh net-autostart default
```

### Issue: "Cannot get interface MTU on 'intra-net'"

**Solution:**
```bash
# Restart the network
sudo virsh net-destroy intra-net
sudo virsh net-start intra-net

# Verify bridge exists
ip link show virbr-internal
```

### Issue: netserver has only 1 NIC

**Solution:**
```bash
# Attach second NIC
sudo virsh shutdown netserver
sudo virsh attach-interface netserver network intra-net --model virtio --config
sudo virsh start netserver
```

### Issue: Both NICs are on the same network

**Solution:**
```bash
# Detach the wrong one and reattach to intra-net
sudo virsh shutdown netserver
sudo virsh detach-interface netserver network --mac XX:XX:XX:XX:XX:XX --config
sudo virsh attach-interface netserver network intra-net --model virtio --config
sudo virsh start netserver
```

### Issue: netserver has 3+ NICs (more than 3 interfaces total)

**Solution:**
```bash
# Remove extra NICs
sudo virsh shutdown netserver
sudo virsh detach-interface netserver network --mac XX:XX:XX:XX:XX:XX --config
sudo virsh start netserver
```

## Ready to Run Playbook

Once all prerequisites are met:

1. ✓ KVM/libvirt installed and running
2. ✓ Two networks exist: default (or bridge) and intra-net
3. ✓ netserver has exactly 2 NICs, one on each network
4. ✓ netserver has internet access
5. ✓ Ansible installed on netserver

You can proceed to clone the repository and run the playbook:

```bash
# On netserver
git clone https://github.com/rofmina/rhel-router-ansible.git
cd rhel-router-ansible
ansible-playbook -i inventory.ini rhel-router.yml
```

## Architecture Diagram

```
┌─────────────────────────────────────────────────────┐
│                  KVM/libvirt Host                    │
│                                                       │
│  ┌────────────────┐         ┌──────────────────┐   │
│  │ default        │         │ intra-net        │   │
│  │ (NAT/bridge)   │         │ (isolated)       │   │
│  │ 192.168.122.0  │         │ no IP/DHCP       │   │
│  └───────┬────────┘         └────────┬─────────┘   │
│          │                           │              │
│          │                           │              │
│  ┌───────▼────────────────────────────▼─────────┐  │
│  │         netserver VM                          │  │
│  │  ┌──────────┐         ┌──────────┐           │  │
│  │  │ NIC 1    │         │ NIC 2    │           │  │
│  │  │ DHCP     │         │ 10.0.1.1 │           │  │
│  │  │ internet │         │ static   │           │  │
│  │  └──────────┘         └──────────┘           │  │
│  │                                               │  │
│  │  Services:                                    │  │
│  │  - IP forwarding / NAT                        │  │
│  │  - DHCP (10.0.1.2-16)                         │  │
│  │  - DNS forwarder                              │  │
│  └───────────────────────────────────────────────┘  │
│                           │                          │
│                           │                          │
│  ┌────────────────────────▼─────────────────────┐   │
│  │           Client VMs                          │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐   │   │
│  │  │ client1  │  │ client2  │  │ client3  │   │   │
│  │  │ 10.0.1.2 │  │ 10.0.1.3 │  │ 10.0.1.4 │   │   │
│  │  └──────────┘  └──────────┘  └──────────┘   │   │
│  └───────────────────────────────────────────────┘   │
│                                                       │
└─────────────────────────────────────────────────────┘
                          │
                          ▼
                      Internet
```

Traffic flow:
1. Client VMs get DHCP from netserver (10.0.1.x)
2. Client traffic → netserver (10.0.1.1)
3. netserver NAT/forwards → external network
4. External network → Internet
