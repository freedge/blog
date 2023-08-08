set -x
ovs-vsctl del-br br-ex
ovn-nbctl ls-del extnet
ovn-nbctl lrp-del rtoe
ovn-nbctl lr-route-del lr
ovn-nbctl lr-nat-del lr
ovn-nbctl lr-lb-del lr lb
ovn-nbctl lb-del ingressrouter
ovn-nbctl lb-del nodeport
ovn-nbctl clear chassis_template_var $(cat /etc/openvswitch/system-id.conf) variables
systemctl stop myhaproxy


# let's try with a second interface on the VM:
set -e
ovs-vsctl add-br br-ex -- add-port br-ex eth1 -- set open . external_ids:ovn-bridge-mappings=datacentre:br-ex
ip link set eth1 up

MAC=00:11:11:11:11:11

ovn-nbctl \
 -- comment create an external network and link it to our existing router: \
 --     ls-add extnet \
 --     lsp-add extnet provnet \
 --     lsp-set-type provnet localnet \
 --     lsp-set-addresses provnet unknown \
 --     lsp-set-options provnet network_name=datacentre \
 --     lsp-add extnet etor \
 --     lsp-set-type etor router \
 --     lrp-add lr rtoe $MAC 10.224.122.18/24 \
 --     lsp-set-options etor router-port=rtoe \
 --     lsp-set-addresses etor "$MAC 10.224.122.18/24" \
 --     lr-route-add lr 0.0.0.0/0 10.224.122.1 \
 -- comment egress traffic getting snatted: \
 --     lr-nat-add lr snat 10.224.122.19 192.168.42.0/24 \
 --     lrp-set-gateway-chassis rtoe $(cat /etc/openvswitch/system-id.conf) \
 -- comment ingress traffic through loadbalancer: \
 --     lr-lb-add lr lb \
 -- comment ingress router for to be exhaustive: \
 --     lb-add ingressrouter 10.224.0.1:80 192.168.42.200:8080 \
 --     ls-lb-add net ingressrouter \
 --     lr-lb-add lr ingressrouter \
 -- comment node port: \
 --     set Chassis_Template_Var $(cat /etc/openvswitch/system-id.conf) variables=NODEIP_IPv4_0="10.224.122.19" \
 --     create load_balancer name=nodeport vips='"^NODEIP_IPv4_0:30000"="192.168.42.100:8080"' protocol=tcp option:template=true option:address-family=ipv4 \
 --     lr-lb-add lr nodeport

systemd-run  --collect --uid haproxy --unit myhaproxy -p NetworkNamespacePath=/var/run/netns/ns2 haproxy -- /etc/haproxy/haproxy1.config
until ip netns exec ns2 curl -so /dev/null --connect-timeout 0.5 --fail 192.168.42.200:8080  ; do sleep .1; done

# DNS service running on each node as daemonset
# TODO

ovn-nbctl --wait=hv sync
ovn-sbctl wait-until port_binding cr-rtoe up=true
ovs-vsctl wait-until interface patch-br-int-to-provnet options:peer=patch-provnet-to-br-int

ip netns exec ns1 ping -c 1 8.8.8.8 -W 1

echo == OK!
