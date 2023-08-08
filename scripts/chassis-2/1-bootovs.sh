# we start with some clean-up
set -x
ip netns del ns1
ovs-vsctl del-port br-int cont1
ovn-nbctl ls-del net
ovn-nbctl lr-del lr

set -e
# SBDB: allow connections from OVN controller
ovn-sbctl set-connection ptcp:6642

# OVS: define our ports and add options for ovn-controller
ovs-vsctl  \
 add-port br-int cont1 -- set interface cont1 type=internal -- \
 set interface cont1 external_ids:iface-id=cont1 -- \
 set open . external_ids:ovn-remote=tcp:127.0.0.1:6642 external_ids:ovn-encap-type=geneve external_ids:ovn-encap-ip=10.224.123.171


# network namespace set-up
ip netns add ns1
ip link set cont1 netns ns1

ip netns exec ns1 ip link set cont1 address 50:54:00:43:01:00
ip netns exec ns1 ip link set cont1 up
ip netns exec ns1 ip link set lo up
ip netns exec ns1 ip addr add 192.168.43.100/24 dev cont1
ip netns exec ns1 ip route add default via 192.168.43.1

ovn-nbctl  \
 -- comment simple logical switch set-up \
 --     ls-add net \
 --     lsp-add net cont1 \
 --     lsp-set-addresses cont1 "50:54:00:43:01:00 192.168.43.100/24" \
 -- comment router: \
 --     lr-add lr \
 --     lrp-add lr lr-net  00:00:00:00:00:01 192.168.43.1/24 \
 --     lsp-add net ls-net \
 --     lsp-set-addresses ls-net "00:00:00:00:00:01 192.168.43.1/24" \
 --     lsp-set-type ls-net router \
 --     lsp-set-options ls-net router-port=lr-net 

ovn-nbctl --wait=hv sync

ovn-sbctl wait-until port_binding cont1 up=true

echo == OK!
