#!/bin/bash

# Import necessary functions from logging.sh
source "$(dirname "$0")/logging.sh"

# Function to handle errors
function handle_error {
  local error_message="$1"
  echo_console_and_log "$error_message"
  warning_message "$error_message"
}

# Function to log errors
function log_error {
  local error_message="$1"
  echo_console_and_log "$error_message"
}

# Function to log warnings
function log_warning {
  local warning_message="$1"
  echo_console_and_log "$warning_message"
}

# Function to log info messages
function log_info {
  local info_message="$1"
  echo_console_and_log "$info_message"
}
