Tracing what's happening in the kernel

For processes stuck:
```
ps -p <pid> -o wchan
cat /proc/<pid>/stack
perf top
echo t > /proc/sysrq-trigger
echo 1 > /proc/sys/kernel/hung_task_timeout_secs
```

To see what functions are called by a process:
```
trace-cmd record -p function_graph -F -- ip link add todel type dummy
trace-cmd report
```

To trace a specific method, with [bpftrace](https://github.com/iovisor/bpftrace/blob/master/docs/reference_guide.md):
```
bpftrace -l '*register_netdevice'
bpftrace -e 'kfunc:register_netdevice { printf("register PID %d %d\n", pid, args->dev->ifindex); } kfunc:__dev_get_by_index { printf("get PID %d %d\n", pid, args->net->ifindex); printf("%s\n", kstack()); }'
```

With [SystemTap](https://fedoraproject.org/wiki/SystemTap), we can also modify variables:
```
mokutil --sb-state
# SecureBoot disabled
DEBUGINFOD_TIMEOUT=3600 stap-prep
stap -L 'kernel.function("*register_netdevice")'
stap -e 'probe kernel.function("register_netdevice") { printf("register PID %d %d\n", pid(), $dev->ifindex); }' 
stap -g -e 'probe kernel.function("register_netdevice") { ((&($dev->nd_net))->net)->ifindex=1; }'
```

Dynamic debugging:
```
grep icmp /sys/kernel/debug/dynamic_debug/control
echo 'file net/ipv6/icmp.c +p' > /sys/kernel/debug/dynamic_debug/control
```

Some functions need something else to activate debugging, eg [lpfc_log_verbose](https://access.redhat.com/articles/337853) for fibre channel debugging.

Crashing on memory corruptions, on cmdline:
```
slub_debug=FPZU panic_on_taint=0x20
```

Tracing SELinux AVC:
```
bpftrace -e 'kfunc:avc_audit_post_callback { printf("get PID %d %s %s \n", pid, kstack(), ustack()); }'
```
