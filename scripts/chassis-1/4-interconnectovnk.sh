set -x

kubectl logs -n ovn-kubernetes  -l name=ovnkube-master  --tail=5 -c ovn-northd

systemctl stop myic-ovnk

kind get kubeconfig -n ovn  > ~/.kube/config
IP=$(podman inspect ovn-control-plane  | jq -r '.[].NetworkSettings.Networks.kind.IPAddress')
POD=$(kubectl get pod -o name -n ovn-kubernetes -l name==ovnkube-master)
runcmd() {
        kubectl exec -ti -n ovn-kubernetes ${POD} -c ovn-northd -- $*
}
CHASSIS=$(runcmd ovs-vsctl --data=json   get open . external_ids:system-id  | jq -r .)

runcmd ovn-nbctl lsp-del lsp-ts1-worker
runcmd ovn-nbctl lrp-del lrp-worker-ts1
runcmd ovn-nbctl lr-route-del ovn_cluster_router 192.168.42.0/24
runcmd ovn-nbctl lr-route-del ovn_cluster_router 10.224.0.0/31
runcmd ovn-nbctl lr-lb-del ovn_cluster_router Service_kube-system/kube-dns_UDP_cluster

ovn-nbctl lr-route-del lr2 10.244.0.0/16
ovn-nbctl lr-route-del lr 10.244.0.0/16
ovn-nbctl lr-route-del lr2 10.96.0.0/16
ovn-nbctl lr-route-del lr 10.96.0.0/16
set -e

runcmd ovs-vsctl set open_vswitch . external_ids:ovn-is-interconn=true

systemd-run --collect --remain-after-exit --unit myic-ovnk -p "ExecStop=/usr/share/ovn/scripts/ovn-ctl stop_ic" -p Type=oneshot -p "EnvironmentFile=-/etc/sysconfig/ovn" -p RuntimeDirectory=ovnk -p BindPaths=/var/run/ovnk:/var/run/ovn -- /usr/share/ovn/scripts/ovn-ctl  \
            --ovn-user=\${OVNK_USER_ID} \
            --ovn-ic-nb-db=tcp:localhost:6645 --ovn-ic-sb-db=tcp:localhost:6646 \
            --ovn-northd-nb-db=tcp:${IP}:6641 --ovn-northd-sb-db=tcp:${IP}:6642 --ovn-ic-logfile=/var/log/ovn/ovnk-ic.log start_ic

runcmd  ovn-nbctl wait-until Logical_Switch ts1 other_config:interconn-ts=ts1

runcmd ovn-nbctl \
 -- comment create port for interconnect switch:  \
 --     lrp-add ovn_cluster_router lrp-worker-ts1 aa:aa:aa:aa:bb:10 169.254.100.10/24 \
 --     lsp-add ts1 lsp-ts1-worker \
 --     lsp-set-addresses lsp-ts1-worker router \
 --     lsp-set-type lsp-ts1-worker router \
 --     lsp-set-options lsp-ts1-worker router-port=lrp-worker-ts1 \
 --     lrp-set-gateway-chassis lrp-worker-ts1 ${CHASSIS} \
 --     lrp-set-options lrp-worker-ts1 gateway_mtu=1400 \
 --     lr-route-add ovn_cluster_router 192.168.42.0/24 169.254.100.1 \
 --     lr-route-add ovn_cluster_router 10.224.0.0/31 169.254.100.1

# This won't work (reliably) as there are already 4 gateway ports on this router        
#  --     lr-lb-add ovn_cluster_router Service_kube-system/kube-dns_UDP_cluster

ovn-nbctl lr-route-add lr2 10.244.0.0/16 169.254.100.10  \
 --     lr-route-add lr 10.244.0.0/16 100.64.0.2 \
 --     lr-route-add lr2 10.96.0.0/16 169.254.100.10 \
 --     lr-route-add lr 10.96.0.0/16 100.64.0.2


runcmd ovn-sbctl wait-until port_binding cr-lrp-worker-ts1 up=true
ovn-sbctl wait-until port_binding lsp-ts1-worker type=remote

# ovs is not binding to a specific IP so it will communicate with its IP on the podman bridge.
ovs-vsctl set open .  external_ids:ovn-encap-type=geneve external_ids:ovn-encap-ip=10.89.0.1,10.224.123.151



echo OK!==

