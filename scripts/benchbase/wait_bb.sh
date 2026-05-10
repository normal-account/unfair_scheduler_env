#!/bin/bash

# Check if the --end parameter was passed
WAIT_FOR_END=false
for arg in "$@"; do
    if [ "$arg" == "--end" ]; then
        WAIT_FOR_END=true
        break
    fi
done

if [ "$WAIT_FOR_END" = true ]; then
    # Wait until the process STOPS (pgrep returns no result)
    while pgrep -f '132\.231\.8\.189\(' > /dev/null; do
        sleep 0.05
    done
else
    # Original logic: Wait until the process STARTS (pgrep finds a match)
    while ! pgrep -f '132\.231\.8\.189\(' > /dev/null; do
        sleep 0.05
    done
fi
