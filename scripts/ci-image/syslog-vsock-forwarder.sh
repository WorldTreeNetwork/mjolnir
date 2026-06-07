#!/bin/bash
# Forward local syslog messages to the host over vsock.
#
# Busybox syslogd doesn't natively speak vsock, so we use socat to bridge
# /dev/log (the Unix datagram socket that syslogd writes to) → vsock CID 2
# port 5001 (the host syslog listener).
#
# This script is installed at /usr/local/bin/syslog-vsock-forwarder inside
# the CI image and started by syslog-vsock.service on boot.
#
# Dependencies: socat (installed in the CI image)
#
# The host listens on vsock CID 2 (VMADDR_CID_HOST) port 5001 and receives
# newline-delimited syslog lines from all running VMs.

exec socat UNIX-RECV:/dev/log,mode=0777 VSOCK-CONNECT:2:5001
