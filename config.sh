#!/bin/bash
# GSPS Configuration File

LOCAL_IP="192.168.122.38" # where nginx binds to
PROVISIONER_IP="192.168.0.103"  # upstream GSPS for --copy mode

# Directory configuration  
REPO_ROOT="$(pwd)" # where nginx serves files from

# Mode conf
TEST_MODE=false
