#!/bin/bash -euv

readonly IMDS_ENDPOINT="http://169.254.169.254/latest/meta-data"
readonly PRIMARY_ENI_MAC_ADDRESS=$(curl -s ${IMDS_ENDPOINT}/mac)
readonly SUBNET_ID=$(curl -s ${IMDS_ENDPOINT}/network/interfaces/macs/${PRIMARY_ENI_MAC_ADDRESS}/subnet-id)
readonly SECURITY_GROUP_ID="$(curl -s ${IMDS_ENDPOINT}/network/interfaces/macs/${PRIMARY_ENI_MAC_ADDRESS}/security-group-ids)"
export AWS_DEFAULT_REGION=$(curl -s ${IMDS_ENDPOINT}/placement/availability-zone | sed -e 's/.$//')
readonly INSTANCE_ID=$(curl -s ${IMDS_ENDPOINT}/instance-id)

## Utils
get_device_by_hwaddr () {
    LANG=C ip -o link | awk -F ': ' -vIGNORECASE=1 '!/link\/ieee802\.11/ && /'"$1"'/ { print $2 }'
}

cidr2mask() {
  local i mask=""
  local full_octets=$(($1/8))
  local partial_octet=$(($1%8))

  for ((i=0;i<4;i+=1)); do
    if [ $i -lt $full_octets ]; then
      mask+=255
    elif [ $i -eq $full_octets ]; then
      mask+=$((256 - 2**(8-$partial_octet)))
    else
      mask+=0
    fi
    test $i -lt 3 && mask+=.
  done

  echo $mask
}


## Prepare ENI
prepare_task_eni () {
    local NETWORK_INTERFACE_INFO=$(aws ec2 create-network-interface \
        --description "my awsvpc task" \
        --subnet-id ${SUBNET_ID} \
        --groups ${SECURITY_GROUP_ID})
    local NETWORK_INTERFACE_ID=$(echo ${NETWORK_INTERFACE_INFO} | jq -r '.NetworkInterface.NetworkInterfaceId')
    readonly MAC_ADDRESS=$(echo ${NETWORK_INTERFACE_INFO} | jq -r '.NetworkInterface.MacAddress')
    echo create eni: ${NETWORK_INTERFACE_ID}

    local DEVICE_INDEX=$(aws ec2 describe-instances --instance-ids ${INSTANCE_ID} \
        | jq -r '.Reservations[].Instances[0].NetworkInterfaces | length')
    aws ec2 attach-network-interface \
        --network-interface-id ${NETWORK_INTERFACE_ID} \
        --instance-id ${INSTANCE_ID} \
        --device-index ${DEVICE_INDEX}
    echo attach eni: ${NETWORK_INTERFACE_ID}, device index: ${DEVICE_INDEX}
}


## Run pause container
run_pause_container () {
    local PAUSE_IMAGE="kubernetes/pause"
    readonly PAUSE_CONTAINER_ID=$(docker run -d --net=none ${PAUSE_IMAGE})
    echo "pause image: ${PAUSE_IMAGE}, pause container id: ${PAUSE_CONTAINER_ID}"
}


## 1. Plugin to assign ENI to a network namespace:
## see https://github.com/aws/amazon-ecs-agent/blob/8b5e18630375fc2ff656704d6228edfe4d412048/proposals/eni.md
### i. Get MAC Address for the ENI from EC2 Instance Metadata Service
get_mac_address_from_metadata () {
    # FIXME confirm mac address of a attached eth<N>
    #readonly MAC_ADDRESS=$(curl -s ${IMDS_ENDPOINT}/network/interfaces/macs/ | head -1 | sed 's|/||g')
    # Note: Omitted getting from metadata
    echo mac address: ${MAC_ADDRESS}
}

### ii. Get ENI device name on default namespace
get_device_name_by_mac_address () {
    # see source /etc/sysconfig/network-scripts/network-functions
    readonly DEVICE_NAME=$(get_device_by_hwaddr ${MAC_ADDRESS})
    echo device name: ${DEVICE_NAME}
}

### iii. Get network gateway mask
get_gateway_info () {
    # e.g SUBNET_CIDR is 10.0.0.0/20
    readonly SUBNET_CIDR=$(curl -s ${IMDS_ENDPOINT}/network/interfaces/macs/${MAC_ADDRESS}/subnet-ipv4-cidr-block)
    # CIDR is 20
    readonly CIDR=$(echo ${SUBNET_CIDR} | grep -oP "(?<=/)[0-9]+")
    # GATEWAY_MASK is 255.255.240.0
    readonly GATEWAY_MASK=$(cidr2mask ${CIDR})
    # LOCAL_NETWORK is 10.0.0.0
    local LOCAL_NETWORK=$(echo ${SUBNET_CIDR} | grep -oP "[^/]+?(?=/)")
    # VPC_ROUTER is 10.0.0.1
    readonly VPC_ROUTER=$(echo ${LOCAL_NETWORK} | sed -r "s|(.*)([0-9]+)|\11|")
    echo "subnet cidir: ${SUBNET_CIDR} => gateway mask: ${GATEWAY_MASK}"
    echo local network: ${LOCAL_NETWORK}, vpc router: ${VPC_ROUTER}
}

### iv. Get Primary IP Address of the ENI
get_primary_ip_address () {
    readonly PRIMARY_IP_ADDRESS=$(ip -4 addr show ${DEVICE_NAME} | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    echo device name: ${DEVICE_NAME}, primariy ip address: ${PRIMARY_IP_ADDRESS}
}

### v. Move the ENI to container's namespace
hack_pause_network_namespace () {
    readonly PAUSE_NETNS="${PAUSE_CONTAINER_ID:0:12}-pause-container-ns"
    readonly PAUSE_PID=$(docker inspect ${PAUSE_CONTAINER_ID} --format '{{.State.Pid}}')
    # create symbolic link to /var/run/netns/ as we should manage the pause container namespace by ip command
    # see http://man7.org/linux/man-pages/man8/ip-netns.8.html
    sudo mkdir -p /var/run/netns
    sudo ln -s /proc/${PAUSE_PID}/ns/net /var/run/netns/${PAUSE_NETNS}
    echo pause network namespace file: 
    sudo ls /var/run/netns/${PAUSE_NETNS}
}

move_eni_to_pause_network_namespace () {
    readonly DEVICE_NAME_ON_PAUSE_NETNS=eth1
    sudo ip link set ${DEVICE_NAME} netns ${PAUSE_PID}
    # rename device name eth<N> to eth1 on pause netns
    sudo ip netns exec ${PAUSE_NETNS} ip link set ${DEVICE_NAME} name ${DEVICE_NAME_ON_PAUSE_NETNS}
    sudo ip netns exec ${PAUSE_NETNS} ip link set ${DEVICE_NAME_ON_PAUSE_NETNS} up
    echo device name on pause netns: 
    sudo ip netns exec ${PAUSE_NETNS} ip link show | grep -o ${DEVICE_NAME_ON_PAUSE_NETNS}
}

### vi. Assign the primary IP Address to interface
reassign_primary_ip_address_to_eni () {
    sudo ip netns exec ${PAUSE_NETNS} ip addr add ${PRIMARY_IP_ADDRESS}/${CIDR} dev ${DEVICE_NAME_ON_PAUSE_NETNS}
    echo primary ip address on pause netns: 
    sudo ip netns exec ${PAUSE_NETNS} ip addr show | grep -o ${PRIMARY_IP_ADDRESS}
}

### vii. Setup route to internet via the gateway
setup_route () {
    sudo ip netns exec ${PAUSE_NETNS} ip route add default via ${VPC_ROUTER} dev ${DEVICE_NAME_ON_PAUSE_NETNS}
    echo routes on pause netns: 
    sudo ip netns exec ${PAUSE_NETNS} ip route show
}

## debug on pause network namespace
into_pause_network_namespace () {
    sudo ip netns exec ${PAUSE_NETNS} bash
}


## 2. Plugin to establish route to ECS Agent for Credentials
VE_EN1="ve-en1"
VE_BR_EN1="ve_br_en1"
ECS_ENI_BR="ecs-eni-br"

### i. ECS Agent determines an available local IP Address from 169.254.0.0/16 (This will be narrowed down to a /22 or /23 before implementation)
determine_local_ip_address () {
    NIKONI=168.252
}

### ii. Create the ecs-eni bridge if needed
create_ecs_eni_bridge () {
    # NOTE: ecs-agent create automatically
    sudo ip link add ${ECS_ENI_BR} type bridge
    sudo ip addr add 169.254.170.1/22 dev ${ECS_ENI_BR}
    return
}

### iii. Create a pair of veth devices
create_veth_pair () {
    # create veth pair. container namespace is ve-en1, bridge namespace is ve_br_eni1
    sudo ip link add ${VE_BR_EN1} type veth peer name ${VE_EN1}
}

### vi. Assign one end of veth interface to the ecs-eni bridge
assign_veth_to_bridge () {
    # connect ve_br_en1 to ecs-eni-br bridge
    sudo ip link set ${VE_BR_EN1} master ${ECS_ENI_BR}
}

### v. Assign the local IP address to the other end of the veth interface and move it to the container's namespace
assgin_local_ip_to_veth_and_move_pause_container_network_namespace () {
    sudo ip link set ${VE_EN1} netns ${PAUSE_PID}
    sudo ip link set dev ${ECS_ENI_BR} up
    sudo ip link set dev ${VE_BR_EN1} up
    sudo ip netns exec ${PAUSE_NETNS} ip link set dev ${VE_EN1} up
    sudo ip netns exec ${PAUSE_NETNS} ip address add 169.254.170.2/22 dev ${VE_EN1}
}

### vi. Create a route to 169.254.170.2 in container's namespace to via the veth interface
create_route_to_veth_bridge () {
    sudo ip netns exec ${PAUSE_NETNS} ip route add 169.254.0.0/22 via 169.254.170.1 dev ${VE_EN1}
}


assign_eni_to_pause_netns () {
    get_mac_address_from_metadata
    get_device_name_by_mac_address
    get_gateway_info
    get_primary_ip_address
    hack_pause_network_namespace
    move_eni_to_pause_network_namespace
    reassign_primary_ip_address_to_eni
    setup_route
    echo "success!"
}

establish_route_ecs_agent () {
    determine_local_ip_address
    create_ecs_eni_bridge
    create_veth_pair
    assign_veth_to_bridge
    assgin_local_ip_to_veth_and_move_pause_container_network_namespace
    create_route_to_veth_bridge
    echo "success!!"
}

main () {
    prepare_task_eni
    sleep 10
    run_pause_container
    assign_eni_to_pause_netns
    establish_route_ecs_agent
}

main
