# rhel-router-ansible

Simple playbook to provision an IPv4 NAT router with DNS and DHCP on RHEL. Intended for virtual machine labs.

## Overview

This Ansible playbook configures a RHEL-based VM as a network router providing:
- **Dual uplink support** - Bridge (priority) or WiFi/NAT fallback
- **NAT routing** - Routes traffic from internal network to internet
- **DHCP server** - Assigns IPs to client VMs (10.0.1.2 - 10.0.1.16)
- **DNS server** - Provides DNS resolution for internal network
- **Domain**: labnet

## Network Topology (3-NIC)

```
                    Internet
                       |
         ______________|______________
        |                            |
   [Bridge]                    [WiFi/NAT]
      |                              |
[enp1s0]                      [enp2s0]
External                          External-nat
(Static IP)                       (DHCP fallback)
priority: 200                     priority: 100
      |______________________________|
                   |
            [netserver]
                   |
            [enp3s0]
            Intranet
          10.0.1.1/24
                   |
   +---------------+---------------+
   |               |               |
[VM1]           [VM2]           [VM3]
10.0.1.2      10.0.1.3       10.0.1.x
```

## Interface Roles

| Interface | Name | Purpose | Priority | Configuration |
|-----------|------|---------|----------|---------------|
| enp1s0 | External | Bridge/Ethernet (primary) | 200 | Static IP |
| enp2s0 | External-nat | WiFi/NAT (fallback) | 100 | DHCP |
| enp3s0 | Intranet | Internal VMs | auto | Static 10.0.1.1/24 |

## Prerequisites

### 1. KVM/libvirt Host Setup

**On RHEL/Rocky/Alma:**
```bash
sudo dnf install -y qemu-kvm libvirt virt-install virt-manager
sudo systemctl enable libvirtd
sudo systemctl start libvirtd
sudo usermod -aG libvirt $USER
```

**On Ubuntu/Debian:**
```bash
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virt-manager
sudo usermod -aG libvirt $USER
sudo usermod -aG kvm $USER
# Log out and back in for group changes
```

### 2. Create Internal Network

**IMPORTANT**: You must create an isolated internal network on your KVM host BEFORE running the playbook.

Run the setup script (provided in this repo):
```bash
./setup-libvirt-network.sh
```

Or manually:
```bash
cat > /tmp/internal-network.xml <<'EOF'
<network>
  <name>intra-net</name>
  <bridge name='virbr-internal' stp='on' delay='0'/>
  <domain name='labnet'/>
  <!-- Isolated network - no DHCP, no NAT -->
  <!-- The netserver VM will provide all services -->
</network>
EOF

sudo virsh net-define /tmp/internal-network.xml
sudo virsh net-start intra-net
sudo virsh net-autostart intra-net
sudo virsh net-list --all
```

### 3. Create/Configure netserver VM

The netserver VM **MUST have exactly THREE network interfaces**:

**Method 1: Create new VM with virt-install**
```bash
virt-install \
  --name netserver \
  --memory 2048 \
  --vcpus 2 \
  --disk size=20 \
  --cdrom /path/to/rhel.iso \
  --network bridge=br0 \
  --network network=default \
  --network network=intra-net \
  --graphics vnc \
  --os-variant rhel9.0
```

**Method 2: Add NICs to existing VM**
```bash
# Shutdown the VM
sudo virsh shutdown netserver

# Attach to default network (WiFi/NAT fallback)
sudo virsh attach-interface netserver network default --model virtio --config --persistent

# Attach to internal network (for VMs)
sudo virsh attach-interface netserver network intra-net --model virtio --config --persistent

# Start the VM
sudo virsh start netserver

# Verify all 3 NICs
sudo virsh domiflist netserver
```

You should see:
```
Interface   Type      Source      Model
---------------------------------------------
vnet0       bridge    br0         virtio    <- External (bridge - priority 200)
vnet1       network   default     virtio    <- External-nat (WiFi/NAT fallback - priority 100)
vnet2       network   intra-net   virtio    <- Intranet (VM network - 10.0.1.1/24)
```

### 4. Install Ansible on netserver

SSH into netserver and install Ansible:
```bash
sudo dnf install -y git ansible-core rhel-system-roles
```

## Installation

### 1. Clone this repository

**On the netserver VM**:
```bash
git clone https://github.com/rofmina/rhel-router-ansible.git
cd rhel-router-ansible
```

### 2. Run the playbook

```bash
ansible-playbook -i inventory.ini rhel-router.yml
```

The playbook will:
1. Verify you have exactly 4 network interfaces (lo + 3 NICs)
2. Configure 3 NetworkManager connections:
   - **External** (enp1s0): Bridge, priority 200, static IP
   - **External-nat** (enp2s0): DHCP, priority 100, auto fallback
   - **Intranet** (enp3s0): Static 10.0.1.1/24 for VMs
3. Install and configure dnsmasq for DHCP/DNS
4. Enable IP forwarding
5. Configure firewall with masquerading

### 3. Verify installation

```bash
# Check interfaces
ip addr show

# Should see:
# - lo: 127.0.0.1
# - External (enp1s0): 10.0.0.190/24 (or your static IP)
# - External-nat (enp2s0): IP from DHCP (e.g., 192.168.122.x) - may not be active
# - Intranet (enp3s0): 10.0.1.1/24

# Check services
systemctl status dnsmasq
sudo firewall-cmd --get-active-zones
sysctl net.ipv4.ip_forward

# Watch DHCP logs
sudo journalctl -u dnsmasq -f
```

## Configure Client VMs

### 1. Attach client VM to internal network

**On KVM host**:
```bash
# Shutdown client
sudo virsh shutdown client-vm

# Attach to intra-net
sudo virsh attach-interface client-vm network intra-net --model virtio --config

# Start client
sudo virsh start client-vm
```

### 2. Verify connectivity

**Inside client VM**:
```bash
# Should get IP via DHCP
ip addr show
# Expected: 10.0.1.x (between .2 and .16)

# Check gateway
ip route show
# Expected: default via 10.0.1.1

# Test connectivity
ping -c 4 10.0.1.1      # netserver
ping -c 4 8.8.8.8       # internet
ping -c 4 google.com    # DNS + internet
```

## Configuration Details

### Network Settings (from playbook)
- **Domain**: labnet
- **Router IP**: 10.0.1.1/24
- **DHCP Range**: 10.0.1.2 - 10.0.1.16
- **DHCP Lease Time**: 12 hours
- **Upstream DNS**: 8.8.8.8

### Files Modified by Playbook
- `/etc/NetworkManager/system-connections/external.nmconnection` (enp1s0 - bridge)
- `/etc/NetworkManager/system-connections/external-nat.nmconnection` (enp2s0 - DHCP fallback)
- `/etc/NetworkManager/system-connections/intranet.nmconnection` (enp3s0 - internal)
- `/etc/dnsmasq.conf`
- `/etc/hosts`

## Troubleshooting

### Playbook fails: "There are X interfaces. Expected 4."
- **Cause**: VM has wrong number of network interfaces
- **Fix**: Ensure VM has exactly 3 NICs (plus loopback = 4 total)
```bash
sudo virsh domiflist netserver
# Should show: bridge + default + intra-net
```

### External-nat interface is not activating
- **Cause**: External (bridge) has higher priority and is active
- **This is expected behavior**: External (priority 200) takes precedence over External-nat (priority 100)
- **If External fails**, External-nat should auto-activate if NetworkManager is configured correctly

### Client VM not getting DHCP
- **Check**: Is client attached to `intra-net` network?
```bash
sudo virsh domiflist client-vm
```
- **Check**: Is dnsmasq running on netserver?
```bash
systemctl status dnsmasq
sudo journalctl -u dnsmasq -f
```

### Client gets IP but no internet
- **Check IP forwarding** on netserver:
```bash
sysctl net.ipv4.ip_forward
# Should be: net.ipv4.ip_forward = 1
```
- **Check masquerading** on netserver:
```bash
sudo firewall-cmd --zone=internal --query-masquerade
# Should return: yes
```
- **Check routing** on netserver:
```bash
ip route show
```

### Cannot connect to netserver console via `virsh console`
- This requires serial console configuration inside the VM
- **Workaround**: Use SSH instead
- **To enable console**:
```bash
# Inside netserver
sudo systemctl enable serial-getty@ttyS0.service
sudo systemctl start serial-getty@ttyS0.service
sudo grubby --update-kernel=ALL --args="console=ttyS0,115200n8"
sudo reboot
```

## Customization

To change network settings, edit the variables at the top of `rhel-router.yml`:

```yaml
vars:
  # External (bridge) - enp1s0 - priority 200
  external_static_ip: "10.0.0.190"  # Change bridge static IP
  external_cidr: "24"
  external_gateway: "10.0.0.1"         # Change gateway
  external_dns: "10.0.0.1"           # Change DNS server

  # External-nat (enp2s0) - priority 100 - DHCP auto

  # Intranet (enp3s0) - internal VMs
  intranet_static_ip: "10.0.1.1"     # Change internal router IP
  intranet_cidr: "24"
  domain_name: "labnet"
  dns_server_ip: "8.8.8.8"
  dhcp_ip_range_start: "10.0.1.2"
  dhcp_ip_range_end: "10.0.1.16"
  dhcp_lease_time: "12h"
```

After changing, re-run the playbook.

## Precautions

**⚠️ WARNING**: This playbook deletes all NetworkManager connections and recreates them!

- Designed to run **locally** on the target VM (not remotely)
- Creates fresh network configuration from scratch
- Always creates an "External" connection to maintain internet access
- Best used on fresh VMs or in lab environments

**DO NOT** run this on production systems or systems where you cannot physically access the console.

## Quick Reference

### On KVM Host
```bash
# List networks
sudo virsh net-list --all

# List VMs and their networks
for vm in $(sudo virsh list --name --all); do 
    echo "=== $vm ==="
    sudo virsh domiflist $vm
done

# Attach VM to internal network
sudo virsh attach-interface <vm-name> network intra-net --model virtio --config
```

### On netserver
```bash
# Quick status check
ip -br addr show
nmcli connection show
systemctl status dnsmasq
sudo firewall-cmd --get-active-zones
sysctl net.ipv4.ip_forward

# Watch DHCP activity
sudo journalctl -u dnsmasq -f

# Restart services
sudo systemctl restart dnsmasq
sudo systemctl restart NetworkManager
```

### On Client VMs
```bash
# Check connectivity
ip addr show
ip route show
ping 10.0.1.1
ping 8.8.8.8
ping google.com

# Renew DHCP
sudo nmcli connection down <connection>
sudo nmcli connection up <connection>
```

## Requirements

- RHEL 8/9, Rocky Linux, AlmaLinux, or compatible
- ansible-core
- rhel-system-roles
- NetworkManager
- firewalld
- dnsmasq (installed by playbook)
- KVM/libvirt host with:
  - Bridge interface (e.g., br0) for primary connection
  - External network (default/NAT) for WiFi fallback
  - Internal network (intra-net, created by setup script) for VMs

## License

BSD-3-Clause

## Author

Original: aakyfun/rhel-router-ansible  
Fork: rofmina/rhel-router-ansible

## Contributing

This is intended for lab environments. Feel free to fork and customize for your needs.

For issues or improvements, please open an issue or pull request.
