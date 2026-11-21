#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
}

@test "validates IPv4 addresses" {
  run is_ipv4 192.168.100.90
  [ "$status" -eq 0 ]
  run is_ipv4 999.1.1.1
  [ "$status" -ne 0 ]
}

@test "validates CIDR lists" {
  run validate_cidr_list '10.0.0.0/8,192.168.0.0/16'
  [ "$status" -eq 0 ]
  run validate_cidr_list '10.0.0.0/33'
  [ "$status" -ne 0 ]
}
