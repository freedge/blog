floating IP on a virtual IP in OVN

interested in learn about gratuitous ARP sent by ovn controller. Related issues:

- https://bugs.launchpad.net/neutron/+bug/1973276
- https://bugs.launchpad.net/tripleo/+bug/1842988 

# setting up a lab

we use 2 [sandbox](https://docs.ovn.org/en/latest/tutorials/ovn-sandbox.html). First one will run
the ovs databases and a first chassis, and a couple of ports. We define an extra frv virtual port.

```
set -xe

# Create our logical switch with one port
ovn-nbctl ls-add fnet
ovn-nbctl lsp-add fnet fr1p
ovn-nbctl lsp-set-addresses fr1p "fa:16:00:00:00:11 192.168.0.11"
ovn-nbctl lsp-add fnet fr2p
ovn-nbctl lsp-set-addresses fr2p "fa:16:00:00:00:12 192.168.0.12"
ovn-nbctl lsp-add fnet fr3p
ovn-nbctl lsp-set-addresses fr3p "fa:16:00:00:00:13 192.168.0.13"
ovn-nbctl lsp-add fnet frv
ovn-nbctl lsp-set-addresses frv "fa:16:00:00:00:05 192.168.0.5"

# Create the logical switch for the public network
ovn-nbctl ls-add public

# Create a logical router and attach both logical switches
ovn-nbctl lr-add lerouter
ovn-nbctl lrp-add lerouter lrp-1 fa:16:00:00:00:01 192.168.0.1/28
ovn-nbctl lsp-add fnet lrp-1-attach
ovn-nbctl lsp-set-type lrp-1-attach router
ovn-nbctl lsp-set-options lrp-1-attach router-port=lrp-1

# add the natting and plumbing to route between networks
ovn-nbctl lr-nat-add lerouter snat 10.224.122.100 192.168.0.0/28
ovn-nbctl lr-nat-add lerouter dnat_and_snat 10.224.122.105 192.168.0.5 frv "00:11:22:33:00:00"
ovn-nbctl lrp-add lerouter lrp-ext fa:16:ff:ff:ff:ff 10.224.122.100/24
ovn-nbctl lsp-add public lrp-ext-attach
ovn-nbctl lsp-set-options lrp-ext-attach router-port=lrp-ext
ovn-nbctl lsp-set-type lrp-ext-attach router
ovn-nbctl lsp-add public provnet
ovn-nbctl lsp-set-type provnet localnet
ovn-nbctl lsp-set-addresses provnet unknown
ovn-nbctl lsp-set-options provnet network_name=public

# enable ports and vip
ovn-nbctl lsp-set-enabled lrp-ext-attach enabled
ovn-nbctl lsp-set-addresses lrp-ext-attach router
ovn-nbctl lsp-set-enabled fr1p enabled
ovn-nbctl lsp-set-enabled fr2p enabled
ovn-nbctl lsp-set-enabled fr3p enabled
ovn-nbctl lsp-set-port-security fr1p "fa:16:00:00:00:11 192.168.0.11 192.168.0.5"
ovn-nbctl lsp-set-port-security fr2p "fa:16:00:00:00:12 192.168.0.12 192.168.0.5"
ovn-nbctl lsp-set-port-security fr3p "fa:16:00:00:00:13 192.168.0.13 192.168.0.5"
ovn-nbctl lsp-set-enabled lrp-1-attach enabled
ovn-nbctl lsp-set-addresses lrp-1-attach router

ovn-nbctl lr-route-add lerouter 0.0.0.0/0 10.224.122.1
ovn-nbctl lrp-set-gateway-chassis lrp-ext  chassis-1 20

# enable garp
ovn-nbctl set logical_switch_port lrp-ext-attach options:nat-addresses=router
ovn-nbctl set logical_switch_port lrp-ext-attach options:exclude-lb-vips-from-garp="true"

# virtual parent setup
ovn-nbctl set logical_switch_port frv type=virtual
ovn-nbctl set logical_switch_port frv options:virtual-ip=192.168.0.5
ovn-nbctl set logical_switch_port frv options:virtual-parents=fr1p,fr2p,fr3p

# complete the ovs set-up
    ovn-sbctl set-connection ptcp:6642:0.0.0.0
ovs-vsctl set open . external_ids:ovn-encap-ip=192.168.121.78

ovs-vsctl add-br br-ex
ovs-vsctl add-port br-ex eth1
ovs-vsctl set open . external-ids:ovn-bridge-mappings=public:br-ex
ip link set eth1 up

for i in 1 2 ; do
ovs-vsctl add-port br-int p$i -- \
    set Interface p$i external_ids:iface-id=fr${i}p -- \
    set Interface p$i type=internal

[[ -f /var/run/netns/n$i ]] || ip netns add n$i
ip link set p$i netns n$i

ip netns exec n$i ip link set dev p$i address fa:16:00:00:00:1$i
ip netns exec n$i ip addr add 192.168.0.1${i}/28 dev p$i
ip netns exec n$i ip link set dev p$i up
ip netns exec n$i ip route add default via 192.168.0.1
done

i=1
ip netns exec n$i ip addr add 192.168.0.5/32 dev p$i
ip netns exec n$i python3 ~/garp.py fa:16:00:00:00:1$i 192.168.0.5 p$i

```

We send a gratuitous ARP from the VM using this script:

```
import sys
from scapy.all import *                                                                               
sendp(Ether(src=sys.argv[1],dst="ff:ff:ff:ff:ff:ff")/ARP(op=1,hwsrc=sys.argv[1],hwdst="00:00:00:00:00:00",psrc=sys.argv[2],pdst=sys.argv[2]),iface=sys.argv[3])
```

We build a second chassis:

```
set -xe
ovs-vsctl set open . external_ids:ovn-remote='"tcp:192.168.121.78:6642"'

ovs-vsctl add-br br-ex
ovs-vsctl add-port br-ex eth1
ovs-vsctl set open . external-ids:ovn-bridge-mappings=public:br-ex
ip link set eth1 up

i=3
ovs-vsctl add-port br-int p$i -- \
    set Interface p$i external_ids:iface-id=fr${i}p -- \
    set Interface p$i type=internal

[[ -f /var/run/netns/n$i ]] || ip netns add n$i
ip link set p$i netns n$i

ip netns exec n$i ip link set dev p$i address fa:16:00:00:00:1$i
ip netns exec n$i ip addr add 192.168.0.1${i}/28 dev p$i
ip netns exec n$i ip link set dev p$i up
ip netns exec n$i ip route add default via 192.168.0.1


ip netns exec n$i ip addr add 192.168.0.5/32 dev p$i
ip netns exec n$i python3 ~/garp.py fa:16:00:00:00:13 192.168.0.5 p$i

```

The ```ovs-sandbox``` script needs to be added to 
- remove the dummy interfaces
- HAVE_OPENSSL=no
- change chassis name on the second chassis

# observing the traffic

checking where traffic gets sent:
```
bridge fdb | grep 00:11:22:33:00:00
```

We put traffic on chassis-2
then move to centralized routing:

```
$ ovn-nbctl lr-nat-list lerouter              
TYPE             EXTERNAL_IP        EXTERNAL_PORT    LOGICAL_IP            EXTERNAL_MAC         LOGICAL_PORT                                                                                              
dnat_and_snat    10.224.122.105                      192.168.0.5           00:11:22:33:00:00    frv
snat             10.224.122.100                      192.168.0.0/28
$ ovn-nbctl lr-nat-del lerouter dnat_and_snat
$ ovn-nbctl lr-nat-add lerouter dnat_and_snat 10.224.122.105 192.168.0.5 
$ ovn-nbctl lr-nat-add lerouter dnat_and_snat 10.224.122.105 192.168.0.5 frv "00:11:22:33:00:00"

```

```
$ sudo tcpdump -i vnet3 not stp -Qin
23:32:28.039461 ARP, Request who-has 10.224.122.105 tell 10.224.122.105, length 28
23:32:28.051924 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2006, length 64
23:32:29.052231 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2007, length 64
23:32:30.042030 ARP, Request who-has 10.224.122.105 tell 10.224.122.105, length 28
23:32:30.052820 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2008, length 64
23:32:31.058419 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2009, length 64
23:32:32.082294 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2010, length 64
23:32:33.106585 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2011, length 64
23:32:33.299363 ARP, Reply 10.224.122.105 is-at 00:11:22:33:00:00 (oui Unknown), length 28
23:32:34.046542 ARP, Request who-has 10.224.122.105 tell 10.224.122.105, length 28
23:32:34.130635 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2012, length 64
23:32:35.154740 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2013, length 64
23:32:36.178405 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2014, length 64
23:32:37.202709 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2015, length 64
23:32:38.226463 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2016, length 64
23:32:39.250606 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2017, length 64
23:32:40.274487 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2018, length 64
23:32:41.298527 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2019, length 64
23:32:42.055123 ARP, Request who-has 10.224.122.105 tell 10.224.122.105, length 28
23:32:42.322406 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2020, length 64
23:32:43.346694 IP 10.224.122.105 > ncelrnd2561: ICMP echo reply, id 267, seq 2021, length 64
```

we can check ARP are sent.

# failover the L3gw

Moving back to centralized dnat:
```
ovn-nbctl lr-nat-del lerouter dnat_and_snat
ovn-nbctl lr-nat-add lerouter dnat_and_snat 10.224.122.105 192.168.0.5 
```

```
$ ip  neigh show to 10.224.122.105
10.224.122.105 dev virbr0 lladdr fa:16:ff:ff:ff:ff STALE

$ bridge  f | grep ff:ff:ff
fa:16:ff:ff:ff:ff dev vnet3 master virbr0 
```

```
ovn-nbctl lrp-set-gateway-chassis lrp-ext  chassis-1 20
# make chassis-2 second the stand-by:
ovn-nbctl lrp-set-gateway-chassis lrp-ext  chassis-2 10
# make chassis-2 primary:
ovn-nbctl lrp-set-gateway-chassis lrp-ext  chassis-2 30
```
current active chassis can be queries in the Port_Binding table:
```
# ovn-sbctl --bare --columns chassis list  port_binding cr-lrp-ext | xargs ovn-sbctl --bare --columns name list chassis
chassis-2

# ovn-sbctl show
Chassis chassis-2
    hostname: sandbox-2
    Encap geneve
        ip: "192.168.121.135"
        options: {csum="true"}
    Port_Binding frv
    Port_Binding cr-lrp-ext
    Port_Binding fr3p
Chassis chassis-1
    hostname: sandbox
    Encap geneve
        ip: "192.168.121.78"
        options: {csum="true"}
    Port_Binding fr1p
    Port_Binding fr2p
```

# playing a bit with ACL

note on Debian, nc runs with: ```nc -u -s 10.224.122.105 -l -p 12345``` to listen on the vip


we block ports. We verify acls work for the actual port:
```
ovn-nbctl acl-del fnet
ovn-nbctl acl-add fnet from-lport 1002  '(inport == "fr3p" && ip)' allow-related
ovn-nbctl acl-add fnet to-lport   1002  '(outport == "fr3p" && ip && icmp)' allow-related
ovn-nbctl acl-add fnet to-lport   1001  '(outport == "fr3p" && ip)' drop
```

but not for the virtual port: this does not drop any traffic
```
ovn-nbctl acl-del fnet
ovn-nbctl acl-add fnet from-lport 1002  '(inport == "frv" && ip)' allow-related
ovn-nbctl acl-add fnet to-lport   1002  '(outport == "frv" && ip && icmp)' allow-related
ovn-nbctl acl-add fnet to-lport   1001  '(outport == "frv" && ip)' drop
```

# MTU issue

in case where traffic goes first to the L3GW, then has to be tunneled to the chassis, we notice:
```
# netstat -s | grep -i fail
    11315929 packet reassemblies failed
    125379 fragments failed
    125379 input ICMP message failed
    0 ICMP messages failed
    0 failed connection attempts

```

matching ICMP packets:
```
Frame 55: 592 bytes on wire (4736 bits), 592 bytes captured (4736 bits)
Linux cooked capture
Internet Protocol Version 4, Src: 192.168.121.78, Dst: 192.168.121.78
Internet Control Message Protocol
    Type: 3 (Destination unreachable)
    Code: 4 (Fragmentation needed)
    Checksum: 0x9e1b [correct]
    [Checksum Status: Good]
    Unused: 0000
    MTU of next hop: 1500
    Internet Protocol Version 4, Src: 192.168.121.78, Dst: 192.168.121.135
    User Datagram Protocol, Src Port: 57882, Dst Port: 6081
    Generic Network Virtualization Encapsulation, VNI: 0x000001
    Ethernet II, Src: fa:16:00:00:00:01 (fa:16:00:00:00:01), Dst: fa:16:00:00:00:13 (fa:16:00:00:00:13)
    Internet Protocol Version 4, Src: 10.224.122.1, Dst: 192.168.0.5
        0100 .... = Version: 4
        .... 0101 = Header Length: 20 bytes (5)
        Differentiated Services Field: 0x00 (DSCP: CS0, ECN: Not-ECT)
        Total Length: 1500
        Identification: 0x06d1 (1745)
        Flags: 0x4000, Don't fragment
        Fragment offset: 0
        Time to live: 63
        Protocol: TCP (6)
        Header checksum: 0xe9bc [correct]
        [Header checksum status: Good]
        [Calculated Checksum: 0xe9bc]
        Source: 10.224.122.1
        Destination: 192.168.0.5
    Transmission Control Protocol, Src Port: 47298, Dst Port: 12345, Seq: 3687381026, Ack: 3888820440
        Source Port: 47298
        Destination Port: 12345
        [Stream index: 3]
        Sequence number: 3687381026    (relative sequence number)
        Sequence number (raw): 3687381026
        Acknowledgment number: 3888820440    (relative ack number)
        Acknowledgment number (raw): 3888820440
        1000 .... = Header Length: 32 bytes (8)
        Flags: 0x010 (ACK)
        Window size value: 502
        [Calculated window size: 502]
        [Window size scaling factor: 128]
        Checksum: 0x6261 incorrect, should be 0x21f0(maybe caused by "TCP checksum offload"?)
        [Checksum Status: Bad]
        [Calculated Checksum: 0x21f0]
        Urgent pointer: 0
        Options: (12 bytes), No-Operation (NOP), No-Operation (NOP), Timestamps
        [Timestamps]
        TCP payload (438 bytes)

```
packet is too big, unfortunately the packet is discarded.

we fix by reducing the MTU so that client and server can negotiate a proper payload size:
```
sudo ip netns exec n3 ip link set p3 mtu 1440
```

# qos

we set-up a lab with
- traffic centralized for the VIP
- L3GW on chassis-1
- vip on chassis-2
- qos:

```
ovn-nbctl qos-add fnet to-lport 100 '(outport == "fr3p" && ip)' rate=1
```

client running ```curl -T /dev/random 10.224.122.105:12345```, 
server running ```sudo ip netns exec n3 nc -s 192.168.0.5 -l -p 12345 > /dev/null```.

we see a nominal upload speed of 35MB/s.

We can set the QoS, then experiment with
```
ovn-nbctl  set  qos a9baa0fb-d614-46a4-922b-3259ccb2a027 bandwidth:rate=2000
```

which all works great. For rate=800, curl shows 98kB/s, iftop -i genev_sys_6081 shows 0.98Mb/s

we do an experiment with UDP traffic. Client running: ```cat /dev/random | nc -u 10.224.122.105 1234```
(causing plenty of ICMP to be discarded in the process)

iftop shows above 2Mb/s, so the QoS is not applied on the L3GW (it forwards all the traffic, and the target chassis
does the QoS)

Traffic is discarded just before being delivered to the VM.

Like for ACL, it needs to be set on the parent port, not on the virtual port.





some links:

https://developers.redhat.com/blog/2018/11/08/how-to-create-an-open-virtual-network-distributed-gateway-router#setup_details

https://bugzilla.redhat.com/show_bug.cgi?id=1762341

https://github.com/ovn-org/ovn/blob/04292cc2dc2c3823b0cf86612e50ad0023bcb73f/controller/pinctrl.c#L4611


