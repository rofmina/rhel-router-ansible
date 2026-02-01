<b>Heads up: I am not working on this anymore. There will be an improved spiritual successor in the aakyfun/lab project. Thanks.</b>

# rhel-router-ansible
Simple playbook to provision an IPv4 NAT router with DNS and DHCP on RHEL. Intended for virtual machine labs.  
This is one of my first Ansible playbooks so be warned :)

## Requirements
Requires ansible-core and rhel-system-roles

**Expects *three* network interfaces (including loopback):**  
One that is already being configured to access the internet gateway via DHCP, another one that is connected to a bridge/switch with an unassigned IPv4 address, and the loopback 'lo' interface always being there. The goal is to provide routing, DHCP, and DNS service to hosts connected to the bridge.

## Installation
If you don't care about applying this play to remote hosts then you can use the provided inventory file to run the play against your local system or virtual machine.

    ansible-playbook -i inventory.ini rhel-router.yml
    
## Precautions
**This play messes around with your NetworkManager connections. In fact, it straight up deletes all of them and starts from scratch!**

This was done to ensure a consistent setup with no duplicates. Please keep this in mind if you need to keep your connections or don't want to lose access to a remote system in the event of a failiure.

This is also the reason why this play is designed to run locally - so you can fix your network if the play somehow breaks it!  
As a saving grace, the play is always going to try to create a automatic connection called 'External' to connect to the internet. So under common circumstances, things should be fine.


# rhel-router-ansible

Simple playbook to provision an IPv4 NAT router with DNS and DHCP on RHEL. Intended for virtual machine labs.

## Overview

This Ansible playbook configures a RHEL-based VM as a network router providing:
- **NAT routing** - Routes traffic from internal network to internet
- **DHCP server** - Assigns IPs to client VMs (10.0.1.2 - 10.0.1.16)
- **DNS server** - Provides DNS resolution for internal network
- **Domain**: labnet

## Network Topology

```
Internet
   |
   |
[KVM Host]
   |
   +--- External Network (default/NAT/bridge)
   |         |
   |    [netserver - NIC1: Gets internet via DHCP]
   |         |
   |    [netserver - NIC2: 10.0.1.1/24]
   |         |
   +--- Internal Network (isolated)
             |
        [Client VMs - DHCP: 10.0.1.2-10.0.1.16]
             |
        Route through netserver to internet
```

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

The netserver VM **MUST have exactly TWO network interfaces**:

**Method 1: Create new VM with virt-install**
```bash
virt-install \
  --name netserver \
  --memory 2048 \
  --vcpus 2 \
  --disk size=20 \
  --cdrom /path/to/rhel.iso \
  --network network=default \
  --network network=intra-net \
  --graphics vnc \
  --os-variant rhel9.0
```

**Method 2: Add second NIC to existing VM**
```bash
# Shutdown the VM
sudo virsh shutdown netserver

# Attach to internal network
sudo virsh attach-interface netserver network intra-net --model virtio --config --persistent

# Start the VM
sudo virsh start netserver

# Verify both NICs
sudo virsh domiflist netserver
```

You should see:
```
Interface   Type      Source      Model
---------------------------------------------
vnet0       network   default     virtio    <- External (internet)
vnet1       network   intra-net   virtio    <- Internal (lab network)
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
1. Verify you have exactly 3 network interfaces (lo + 2 NICs)
2. Identify external (has IP) and internal (no IP) interfaces
3. Configure NetworkManager connections
4. Install and configure dnsmasq for DHCP/DNS
5. Enable IP forwarding
6. Configure firewall with masquerading

### 3. Verify installation

```bash
# Check interfaces
ip addr show

# Should see:
# - lo: 127.0.0.1
# - External NIC: IP from DHCP (e.g., 192.168.122.x)
# - Internal NIC: 10.0.1.1/24

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
- `/etc/NetworkManager/system-connections/internal.nmconnection`
- `/etc/NetworkManager/system-connections/external.nmconnection`
- `/etc/dnsmasq.conf`
- `/etc/sysctl.d/ip4fw.conf`
- `/etc/hosts`

## Troubleshooting

### Playbook fails: "There are X interfaces. I support only three."
- **Cause**: VM has wrong number of network interfaces
- **Fix**: Ensure VM has exactly 2 NICs (plus loopback = 3 total)
```bash
sudo virsh domiflist netserver
```

### Playbook fails: "All interfaces are currently assigned an ip address"
- **Cause**: Both NICs have IPs, no interface available for internal network
- **Fix**: One NIC must have no IP. Delete auto-created connection:
```bash
sudo nmcli connection show
sudo nmcli connection delete "Wired connection 1"  # or similar name
```

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

To change network settings, edit the variables in `rhel-router.yml`:

```yaml
- name: Set some basic facts for config files
  set_fact:
    domain_name: "labnet"           # Change domain name
    dns_server_ip: "8.8.8.8"        # Change upstream DNS
    cidr: "24"                      # Change subnet mask
    router_static_ip: "10.0.1.1"    # Change router IP
    dhcp_ip_range_start: "10.0.1.2" # Change DHCP range start
    dhcp_ip_range_end: "10.0.1.16"  # Change DHCP range end
    dhcp_lease_time: "12h"          # Change lease time
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
  - External network (default or custom bridge)
  - Internal network (intra-net, created by setup script)

## License

BSD-3-Clause

## Author

Original: aakyfun/rhel-router-ansible  
Fork: rofmina/rhel-router-ansible

## Contributing

This is intended for lab environments. Feel free to fork and customize for your needs.

For issues or improvements, please open an issue or pull request.
