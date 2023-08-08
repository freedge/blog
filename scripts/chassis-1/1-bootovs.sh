# we start with some clean-up
set -x
ip netns del ns1
ip netns del ns2
ip netns del ns3
ovs-vsctl del-br br-ex
ovs-vsctl del-port br-int cont1 -- del-port br-int cont2 -- del-port br-int cont3
ovn-nbctl ls-del net
ovn-nbctl ls-del net2
ovn-nbctl ls-del extnet
ovn-nbctl lr-del lr
ovn-nbctl lb-del lb
ovn-nbctl --all destroy dns
pkill python3
systemctl stop myhaproxy

set -e
# SBDB: allow connections from OVN controller
ovn-sbctl set-connection ptcp:6642

# OVS: define our ports and add options for ovn-controller
ovs-vsctl  \
 add-port br-int cont1 -- set interface cont1 type=internal -- \
 add-port br-int cont2 -- set interface cont2 type=internal -- \
 add-port br-int cont3 -- set interface cont3 type=internal -- \
 set interface cont1 external_ids:iface-id=cont1 -- \
 set interface cont2 external_ids:iface-id=cont2 -- \
 set interface cont3 external_ids:iface-id=cont3 -- \
 set open . external_ids:ovn-remote=tcp:127.0.0.1:6642 external_ids:ovn-encap-type=geneve external_ids:ovn-encap-ip=10.224.123.151


# network namespace set-up
ip netns add ns1
ip netns add ns2
ip netns add ns3
ip link set cont1 netns ns1
ip link set cont2 netns ns2
ip link set cont3 netns ns3

ip netns exec ns1 ip link set cont1 address 50:54:00:00:01:00
ip netns exec ns1 ip link set cont1 up
ip netns exec ns1 ip link set lo up
ip netns exec ns1 ip addr add 192.168.42.100/24 dev cont1
ip netns exec ns1 ip route add default via 192.168.42.1

ip netns exec ns2 ip link set cont2 address 50:54:00:00:02:00
ip netns exec ns2 ip link set cont2 up
ip netns exec ns2 ip link set lo up
ip netns exec ns2 ip addr add 192.168.42.200/24 dev cont2
ip netns exec ns2 ip route add default via 192.168.42.1

ip netns exec ns3 ip link set cont3 address 50:54:00:00:03:00
ip netns exec ns3 ip link set cont3 up
ip netns exec ns3 ip addr add 10.225.42.10/24 dev cont3
ip netns exec ns3 ip route add default via 10.225.42.1

# boot a little server
systemd-run --collect --unit mypyserver -p DynamicUser=true -p NetworkNamespacePath=/var/run/netns/ns1 python3 -m http.server -d /etc/ 8080
until ip netns exec ns1 curl -so /dev/null --fail 192.168.42.100:8080  ; do sleep .1; done

ovn-nbctl  \
 -- comment simple logical switch set-up \
 --     ls-add net \
 --     lsp-add net cont1 \
 --     lsp-set-addresses cont1 "50:54:00:00:01:00 192.168.42.100/24" \
 --     lsp-add net cont2 \
 --     lsp-set-addresses cont2 "50:54:00:00:02:00 192.168.42.200/24" \
 -- comment second logical switch with router: \
 --     ls-add net2 \
 --     lsp-add net2 cont3 \
 --     lsp-set-addresses cont3 "50:54:00:00:03:00 10.225.42.10/24" \
 --     lr-add lr \
 --     lrp-add lr lr-net  00:00:00:00:00:01 192.168.42.1/24 \
 --     lrp-add lr lr-net2 00:00:00:00:00:01 10.225.42.1/24 \
 --     lsp-add net ls-net \
 --     lsp-add net2 ls-net2 \
 --     lsp-set-addresses ls-net "00:00:00:00:00:01 192.168.42.1/24" \
 --     lsp-set-addresses ls-net2 "00:00:00:00:00:01 10.225.42.1/24" \
 --     lsp-set-type ls-net router \
 --     lsp-set-type ls-net2 router \
 --     lsp-set-options ls-net router-port=lr-net \
 --     lsp-set-options ls-net2 router-port=lr-net2 \
 -- comment add load balancer: \
 --     lb-add lb 10.224.0.0:80 192.168.42.100:8080 \
 --     ls-lb-add net lb \
 --     ls-lb-add net2 lb \
 --     set load_balancer lb options:hairpin_snat_ip="169.254.0.0" \
 -- comment for the fun of it set up a DNS record: \
 --     --id=@rec create dns records=toto="10.224.0.0" \
 --     set logical_switch net2 dns_records=@rec

ovn-nbctl --wait=hv sync

ovn-sbctl wait-until port_binding cont1 up=true \
     --   wait-until port_binding cont2 up=true \
     --   wait-until port_binding cont3 up=true

ovs-vsctl wait-until interface cont1 external_ids:ovn-installed=true \
     --   wait-until interface cont2 external_ids:ovn-installed=true \
     --   wait-until interface cont3 external_ids:ovn-installed=true

ip netns exec ns3 curl  -so /dev/null --fail 10.224.0.0
ip netns exec ns3 dig +retry=0 +timeout=1 +noedns +short a @10.225.42.1 toto
echo === ok !
