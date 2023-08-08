set -x
ovn-nbctl lrp-del lrp-lr2-ts1
ovn-nbctl lsp-del lsp-ts1-lr2
ovn-nbctl lr-route-del lr
systemctl stop myic

set -e

ovn-nbctl set NB_Global . name=rhel
ovn-nbctl set-connection ptcp:6641

systemd-run --collect --remain-after-exit --unit myic -p "ExecStop=/usr/share/ovn/scripts/ovn-ctl stop_ic" -p Type=oneshot -p "EnvironmentFile=-/etc/sysconfig/ovn" -- /usr/share/ovn/scripts/ovn-ctl  \
            --ovn-user=\${OVN_USER_ID} \
            --ovn-ic-nb-db=tcp:10.224.123.151:6645 --ovn-ic-sb-db=tcp:10.224.123.151:6646 \
            --ovn-northd-nb-db=tcp:localhost:6641 --ovn-northd-sb-db=tcp:localhost:6642 start_ic

ovs-vsctl set open_vswitch . external_ids:ovn-is-interconn=true
ovn-nbctl wait-until Logical_Switch ts1 other_config:interconn-ts=ts1

ovn-nbctl \
 -- comment create port for interconnect switch:  \
 --     lrp-add lr lrp-lr2-ts1 aa:aa:aa:aa:aa:02 169.254.100.2/24 \
 --     lsp-add ts1 lsp-ts1-lr2 \
 --     lsp-set-addresses lsp-ts1-lr2 router \
 --     lsp-set-type lsp-ts1-lr2 router \
 --     lsp-set-options lsp-ts1-lr2 router-port=lrp-lr2-ts1 \
 --     lrp-set-gateway-chassis lrp-lr2-ts1 $(cat /etc/openvswitch/system-id.conf) \
 --     lrp-set-options lrp-lr2-ts1 gateway_mtu=1400 \
 --     lr-route-add lr 0.0.0.0/0 169.254.100.1 

ovn-sbctl wait-until port_binding cr-lrp-lr2-ts1 up=true
ovn-sbctl wait-until port_binding lsp-ts1-lr1

ip netns exec ns1  curl -so /dev/null --fail 10.224.0.0


echo == OK!

