#!/bin/bash
# Setup script for libvirt internal network
# This must be run on the KVM/libvirt HOST, not inside VMs

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=================================="
echo "Libvirt Network Setup for rhel-router-ansible"
echo -e "==================================${NC}"
echo ""

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}ERROR: This script must be run with sudo${NC}"
    echo "Usage: sudo ./setup-libvirt-network.sh"
    exit 1
fi

# Check if virsh is available
if ! command -v virsh &> /dev/null; then
    echo -e "${RED}ERROR: virsh command not found${NC}"
    echo "Please install libvirt first:"
    echo ""
    echo "On RHEL/Rocky/Alma:"
    echo "  sudo dnf install -y libvirt"
    echo ""
    echo "On Ubuntu/Debian:"
    echo "  sudo apt install -y libvirt-daemon-system libvirt-clients"
    exit 1
fi

# Check if libvirtd is running
if ! systemctl is-active --quiet libvirtd; then
    echo -e "${YELLOW}WARNING: libvirtd is not running${NC}"
    echo "Starting libvirtd..."
    systemctl start libvirtd
    systemctl enable libvirtd
fi

echo "Checking existing networks..."
echo ""

# Check if intra-net already exists
if virsh net-info intra-net &>/dev/null; then
    echo -e "${YELLOW}Network 'intra-net' already exists${NC}"
    virsh net-info intra-net
    echo ""
    read -p "Do you want to recreate it? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Destroying and undefining intra-net..."
        virsh net-destroy intra-net 2>/dev/null || true
        virsh net-undefine intra-net
    else
        echo "Keeping existing intra-net network"
        echo ""
        echo -e "${GREEN}Setup complete!${NC}"
        echo ""
        echo "Existing networks:"
        virsh net-list --all
        exit 0
    fi
fi

echo "Creating internal network definition..."

# Create temporary XML file
cat > /tmp/intra-net.xml <<'EOF'
<network>
  <n>intra-net</n>
  <bridge name='virbr-internal' stp='on' delay='0'/>
  <domain name='labnet'/>
  <!-- Isolated network with no DHCP or NAT -->
  <!-- The netserver VM will provide routing, DHCP, and DNS -->
  <!-- This is just a virtual switch that VMs connect to -->
</network>
EOF

echo "Defining network..."
virsh net-define /tmp/intra-net.xml

echo "Starting network..."
virsh net-start intra-net

echo "Enabling autostart..."
virsh net-autostart intra-net

# Clean up
rm -f /tmp/intra-net.xml

echo ""
echo -e "${GREEN}✓ Network setup complete!${NC}"
echo ""

echo "Current networks:"
virsh net-list --all
echo ""

echo "Bridge interface:"
ip link show virbr-internal
echo ""

echo -e "${BLUE}=================================="
echo "Next Steps"
echo -e "==================================${NC}"
echo ""
echo "1. Create or configure your netserver VM with TWO NICs:"
echo "   - NIC 1: Connected to 'default' or bridge (for internet)"
echo "   - NIC 2: Connected to 'intra-net' (for internal network)"
echo ""
echo "   Example for NEW VM:"
echo "   virt-install \\"
echo "     --name netserver \\"
echo "     --memory 2048 \\"
echo "     --vcpus 2 \\"
echo "     --disk size=20 \\"
echo "     --cdrom /path/to/rhel.iso \\"
echo "     --network network=default \\"
echo "     --network network=intra-net \\"
echo "     --os-variant rhel9.0"
echo ""
echo "   Example for EXISTING VM:"
echo "   sudo virsh shutdown netserver"
echo "   sudo virsh attach-interface netserver network intra-net --model virtio --config"
echo "   sudo virsh start netserver"
echo ""
echo "2. Verify netserver has 2 NICs:"
echo "   sudo virsh domiflist netserver"
echo ""
echo "3. SSH into netserver and run the Ansible playbook:"
echo "   cd rhel-router-ansible"
echo "   ansible-playbook -i inventory.ini rhel-router.yml"
echo ""
echo "4. Connect client VMs to intra-net:"
echo "   sudo virsh attach-interface <client-vm> network intra-net --model virtio --config"
echo ""
echo -e "${GREEN}Setup script complete!${NC}"
