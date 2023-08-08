set -x
systemctl stop openvswitch
systemctl stop ovn-controller
systemctl stop ovn-northd
systemctl stop myglobalovsdb
systemctl stop myic
systemctl stop myserver
systemctl stop myhaproxy

rm /etc/ovn/ovn_ic_nb_db.db
rm /etc/ovn/ovn_ic_sb_db.db
rm /etc/openvswitch/conf.db
rm /var/lib/ovn/ovnsb_db.db
rm /var/lib/ovn/ovnnb_db.db


set -e
systemctl start openvswitch
systemctl start ovn-controller
systemctl start ovn-northd



ovn-sbctl set-connection ptcp:6642
ovs-vsctl set open . \
	external_ids:ovn-remote=tcp:127.0.0.1:6642 external_ids:ovn-encap-type=geneve external_ids:ovn-encap-ip=10.224.123.151

# we ensure this one is created here, as deleting and recreating it make ovn-controller core
ovn-nbctl create Chassis_Template_Var chassis=$(cat /etc/openvswitch/system-id.conf) 
ovn-nbctl --wait=hv sync
ovn-sbctl wait-until chassis `cat /etc/openvswitch/system-id.conf`
ovs-vsctl wait-until port br-int

echo OK
