set -x
ovn-ic-nbctl ts-del ts1
ovn-nbctl lrp-del lrp-lr1-ts1
ovn-nbctl lr-del lr2
ovn-nbctl lsp-del ls2-net
ovn-nbctl ls-del join
ovn-nbctl lrp-del lrj
ovn-nbctl lr-route-del lr  192.168.43.0/24
lr-nat-del lr snat 10.224.122.20 192.168.43.0/24
systemctl stop myglobalovsdb
systemctl stop myic

set -e
systemd-run --collect --remain-after-exit --unit myglobalovsdb -p "ExecStop=/usr/share/ovn/scripts/ovn-ctl stop_ic_ovsdb" -p Type=oneshot -p "EnvironmentFile=-/etc/sysconfig/ovn" -- /usr/share/ovn/scripts/ovn-ctl \
	    --ovn-user=\${OVN_USER_ID} \
	    --db-ic-nb-create-insecure-remote=yes           --db-ic-sb-create-insecure-remote=yes start_ic_ovsdb

ovn-nbctl set NB_Global . name=raw
ovn-nbctl set-connection ptcp:6641

systemd-run --collect --remain-after-exit --unit myic -p "ExecStop=/usr/share/ovn/scripts/ovn-ctl stop_ic" -p Type=oneshot -p "EnvironmentFile=-/etc/sysconfig/ovn" -- /usr/share/ovn/scripts/ovn-ctl  \
	    --ovn-user=\${OVN_USER_ID} \
	    --ovn-ic-nb-db=tcp:localhost:6645 --ovn-ic-sb-db=tcp:localhost:6646 \
            --ovn-northd-nb-db=tcp:localhost:6641 --ovn-northd-sb-db=tcp:localhost:6642 start_ic

ovs-vsctl set open_vswitch . external_ids:ovn-is-interconn=true
ovn-ic-nbctl ts-add ts1
ovn-nbctl wait-until Logical_Switch ts1 other_config:interconn-ts=ts1

ovn-nbctl \
 -- comment create a join net to connect routers: \
 --     ls-add join \
 --     lrp-add lr lrj 00:00:01:00:00:01 100.64.0.1/24 \
 --     lsp-add join jlr \
 --     lsp-set-addresses jlr "00:00:01:00:00:01 100.64.0.1/24" \
 --     lsp-set-type jlr router \
 --     lsp-set-options jlr router-port=lrj \
 -- comment create a new router as loadbalancer is not supported on routers having 2 gateways: \
 --     lr-add lr2 \
 --     lrp-add lr2 lr2j  00:00:01:00:00:02 100.64.0.2/24 \
 --     lsp-add join jlr2 \
 --     lsp-set-addresses jlr2 "00:00:01:00:00:02 100.64.0.2/24" \
 --     lsp-set-type jlr2 router \
 --     lsp-set-options jlr2 router-port=lr2j \
 -- comment create port for interconnect switch:  \
 --     lrp-add lr2 lrp-lr1-ts1 aa:aa:aa:aa:aa:01 169.254.100.1/24 \
 --     lsp-add ts1 lsp-ts1-lr1 \
 --     lsp-set-addresses lsp-ts1-lr1 router \
 --     lsp-set-type lsp-ts1-lr1 router \
 --     lsp-set-options lsp-ts1-lr1 router-port=lrp-lr1-ts1 \
 --     lrp-set-gateway-chassis lrp-lr1-ts1 $(cat /etc/openvswitch/system-id.conf) \
 --     lrp-set-options lrp-lr1-ts1 gateway_mtu=1400 \
 -- comment make our loadbalancer available: \
 --     lr-lb-add lr2 lb \
 -- comment add route between our 3 switches: \
 --     lr-route-add lr2 192.168.43.0/24 169.254.100.2  \
 --     lr-route-add lr2 0.0.0.0/0 100.64.0.1 \
 --     lr-route-add lr  192.168.43.0/24 100.64.0.2 \
 -- comment snat for traffic to external from the remote az \
 --     lr-nat-add lr snat 10.224.122.20 192.168.43.0/24

ovn-sbctl wait-until port_binding cr-lrp-lr1-ts1 up=true

echo == OK!
