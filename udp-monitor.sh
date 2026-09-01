#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
# Define data file paths
UDP_DIR="/root/udp"
PORTS_CONF="$UDP_DIR/ports.conf"
DATA_FILE="$UDP_DIR/data.txt"

# Function to get bytes for a specific port range
get_bytes() {
    local port_range=$1
    nft list ruleset | grep "udp sport $port_range" | awk '/udp sport/{for(i=1;i<=NF;i++) {if ($i=="bytes") bytes=$(i+1)}} END{print bytes}'
}

# Function to format bytes to human-readable units
format_bytes() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then
        echo "0 B"
    elif [ "$bytes" -lt 1024 ]; then
        echo "$bytes B"
    elif [ "$bytes" -lt 1048576 ]; then
        printf "%.2f KB\n" "$(echo "scale=2; $bytes/1024" | bc)"
    elif [ "$bytes" -lt 1073741824 ]; then
        printf "%.2f MB\n" "$(echo "scale=2; $bytes/1048576" | bc)"
    else
        printf "%.2f GB\n" "$(echo "scale=2; $bytes/1073741824" | bc)"
    fi
}

# Clear the data file
> "$DATA_FILE"

# Process each port range
while IFS='|' read -r remark port_range || [[ -n "$remark" ]]; do
    if [ -z "$port_range" ]; then
        continue
    fi
    
    # Get and format bytes for this port range
    bytes=$(get_bytes "$port_range")
    if [ -z "$bytes" ]; then
        bytes=0
    fi
    formatted_bytes=$(format_bytes "$bytes")
    
    # Write to data file
    echo "[$remark]" >> "$DATA_FILE"
    echo "Month: $formatted_bytes" >> "$DATA_FILE"
done < "$PORTS_CONF"
