#!/usr/bin/env bash
#
# but - [b]ash [u]niversal [t]esting
# https://github.com/urzo/but
#
# Copyright 2019
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eou pipefail
####################################################################################
# magic variables
####################################################################################
IFS=$'\r\n'
__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__file="${__dir}/$(basename "${BASH_SOURCE[0]}")"
__base="$(basename "${__file}" .bash)"
__root="$(cd "$(dirname "${__dir}")" && pwd)"
####################################################################################
# utility functions
####################################################################################
::check_command() {
  local cmd="${1:?"Require a command name"}"
  bash -c "command -v ${cmd}" >/dev/null 2>&1
}
::log() {
  local msg="${1:-""}"
  local color="${2:-"15"}"
  local fdate
  fdate=$(date +'%Y-%m-%d %H:%M:%S')
  tput setaf "${color}"
  tput bold
  printf "[%s] %s\n" "${fdate}" "${msg}"
  tput sgr0
}
::err() {
  ::log "${1:-""}" 196 >&2
}
####################################################################################
# validate bash version
####################################################################################
[[ "${BASH_VERSION:0:1}" -lt 4 ]] && ::err "but only support Bash versions > 4" && exit 2
####################################################################################
# validate dependencies
####################################################################################
declare -ra DEPENDENCIES=("jq" "gsed" "gstat")
for dep in "${DEPENDENCIES[@]}"; do
  if ! ::check_command "${dep}"; then
    ::err "command ${dep} is required for but to run"
    exit 2
  fi
done
####################################################################################
# enable globbing, done after bash version validation
####################################################################################
shopt -s globstar
####################################################################################
# source a .env file if one exists in the current context
####################################################################################
# shellcheck disable=SC1090
[[ -f "${PWD}/.env" ]] && set -a && source "${PWD}/.env" && set +a
####################################################################################
# variables
####################################################################################
declare BUT__INSTANCE_NAME=""
# configuration
declare BUT__CONFIG_SRC="${BUT__CONFIG_SRC:-"${PWD}"}"
declare BUT__CONFIG_OUTPUT="${BUT__CONFIG_OUTPUT:-"tap"}"
declare BUT__CONFIG_ROOT=""
# private
declare BUT__TMP_FILES=""
declare BUT__LOCKFILE=""
declare BUT__ENVFILE=""
declare BUT__SUITECACHE=""
declare BUT__TESTCACHE=""
####################################################################################
# errors / exit codes
####################################################################################
declare -r ERR_INVALID_CONFIG_SRC=3
declare -r ERR_INVALID_CONFIG=4
declare -r ERR_INVALID_SUITE=5
####################################################################################
# validate required environment variables
####################################################################################
if [[ -z "${BUT__CONFIG_SRC:-""}" ]] || [[ ! -d "${BUT__CONFIG_SRC:-""}" ]]; then
  ::err <<EOF
BUT__CONFIG_SRC environment variable MUST be set and MUST be a valid directory path
or a .butrc MAY be present in the current directory.
EOF
  exit ${ERR_INVALID_CONFIG_SRC}
fi
####################################################################################
# process EXIT handler
####################################################################################
::cleanup() {
  [[ -f "${BUT__LOCKFILE}" ]] && rm "${BUT__LOCKFILE}"
  # shellcheck disable=SC2128
  if [[ -n "${BUT__TMP_FILES}" ]] && [[ "${#BUT__TMP_FILES}" -gt 0 ]]; then
    for tmp_file in "${BUT__TMP_FILES[@]}"; do
      [[ -f "${tmp_file}" ]] && rm "${tmp_file}"
    done
  fi
  exit 255
}
trap ::cleanup EXIT
####################################################################################
# logging functions
####################################################################################
::log::ok() {
  ::log "${1}" 120
}
::log::warn() {
  ::log "${1}" 227
}
::log::debug() {
  local msg="${1-""}"
  local output_type="${2:-""}"
  if [[ -n "${output_type}" ]]; then
    if [[ "${output_type}" == "json" ]]; then
      msg="$(echo "${msg}" | jq -r .)"
    elif [[ "${output_type}" == "file" ]]; then
      msg="$(cat "${msg}")"
    elif [[ "${output_type}" == "array" ]]; then
      msg="$(echo "${msg}" | tr ' ' '\n')"
    fi
  fi
  echo -e "${msg}"
}
####################################################################################
# output type utility functions
####################################################################################
::is_tap() {
  if [[ "${BUT__CONFIG_OUTPUT}" == "tap" ]]; then return 0; else return 1; fi
}
::is_verbose() {
  if [[ "${BUT__CONFIG_OUTPUT}" == "verbose" ]]; then return 0; else return 1; fi
}
::is_json() {
  if [[ "${BUT__CONFIG_OUTPUT}" == "json" ]]; then return 0; else return 1; fi
}
# log function wrappers which use the output type to conditionally print output
::ok() {
  if ::is_verbose; then ::log::ok "${1:-""}"; fi
}
::info() {
  if ::is_verbose; then ::log "${1:-""}"; fi
}
::warn() {
  if ::is_verbose; then ::log::warn "${1:-""}"; fi
}
::debug() {
  if ::is_verbose; then ::log::debug "${1:-""}" "${2-""}"; fi
}
####################################################################################
# general utility functions
####################################################################################
::join_by() {
  local delim=$1
  shift
  echo -n "$1"
  shift
  printf "%s" "${@/#/$delim}"
}
::noop() {
  :
}
####################################################################################
# TAP output utility functions
####################################################################################
::tap_start() {
  if ! ::is_tap; then return 0; fi
  local -i total_tests="${1:?"Require the total count of tests"}"
  echo "TAP version 13"
  echo "1..${total_tests}"
}
::tap() {
  if ! ::is_tap; then return 0; fi
  local -i status="${1:?"Require a test status"}"
  local -i index="${2:?"Require a test index"}"
  local description="${3:-""}"
  local output=""
  if [[ "${status}" -eq 0 ]]; then output+="ok"; else output+="not ok"; fi
  output+=" ${index}"
  if [[ -n "${description}" ]]; then output+=" ${description}"; fi
  echo "${output}"
}
::tap_comment() {
  if ! ::is_tap; then return 0; fi
  local comment="${1:?"Require a comment string"}"
  printf "#\n# %s\n#" "${comment}"
}
::tap_end() {
  if ! ::is_tap; then return 0; fi
  local -i total_tests="${1:?"Require the total count of tests"}"
  local -i total_failed="${2:?"Require the total amount of failed tests"}"
  local failed_tests="${3:-""}"
  local -i total_passed=$((total_tests - total_failed))
  local percent
  if [[ "${total_tests}" -gt 0 ]]; then
    percent=$(echo "scale=2; 100 * (${total_passed}/${total_tests})" | bc -l)
  else
    percent="00.00"
  fi
  if [[ "${total_failed}" -gt 0 ]] && [[ -n "${total_failed}" ]]; then
    echo "FAILED tests ${failed_tests}"
  fi
  echo "Failed ${total_failed}/${total_tests} tests, ${percent}% okay"
}
####################################################################################
# configuration utility function
####################################################################################
::source_config() {
  local config="${BUT__CONFIG_SRC}/.butrc"
  if [[ ! -r "${config}" ]]; then
    ::err ".butrc config not found in directory ${BUT__CONFIG_SRC}"
    ::warn "make sure that the BUT__CONFIG_SRC points to a directory that contains a .butrc file"
    exit ${ERR_INVALID_CONFIG_SRC}
  fi

  local -a expected_keys=("name" "root")
  ::info "validating configuration from ${config}"
  for key in "${expected_keys[@]}"; do
    # shellcheck disable=SC2086
    if [[ -z "$(jq -r '.'${key}'?' "${config}")" ]]; then
      ::err "${key} not found in ${config}"
      exit ${ERR_INVALID_CONFIG}
    fi
  done
  ::ok "configuration validated"

  ::info "reading configuration from ${config}"

  BUT__INSTANCE_NAME="$(jq -r .name "${config}")"
  if [[ -z "${BUT__INSTANCE_NAME}" ]]; then
    ::err ".butrc must have a string 'name' identifier"
    exit ${ERR_INVALID_CONFIG}
  fi

  ::ok "instance name set"
  ::debug "${BUT__INSTANCE_NAME}"

  local tmp_dir="/tmp/${BUT__INSTANCE_NAME}"

  BUT__SUITECACHE="${tmp_dir}/suites"
  BUT__TESTCACHE="${tmp_dir}/tests"
  BUT__LOCKFILE="${tmp_dir}/but.lock"
  BUT__ENVFILE="${tmp_dir}/.env"

  if [[ -n "$(jq -r '.tmp[]?' "${config}")" ]]; then
    BUT__TMP_FILES=("$(jq -r '.tmp | to_entries[] | .value' "${config}")")
    ::ok "tmp files registered"
    ::debug "${BUT__TMP_FILES[*]}"
  fi

  BUT__TEST_ROOT="$(jq -r .root? "${config}")"
  if [[ -z "${BUT__TEST_ROOT}" ]] &&
    [[ ! -d "${BUT__TEST_ROOT}" ]] &&
    [[ ! -L "${BUT__TEST_ROOT}" ]]; then
    ::err ".butrc must have a 'root' key with a valid directory path"
    exit ${ERR_INVALID_CONFIG}
  fi
  ::ok "test source set"
  ::debug "${BUT__TEST_ROOT}"

  ::info "checking for existing configuration"
  ::debug "${tmp_dir}"
  local -a __existing_dirs=("${tmp_dir}" "${BUT__SUITECACHE}" "${BUT__TESTCACHE}")
  local -a __existing_confs=("${BUT__ENVFILE}")
  local has_existing_configs=true

  for dir in "${__existing_dirs[@]}"; do
    if [[ ! -d "${dir}" ]]; then has_existing_configs=false; fi
  done
  for conf in "${__existing_confs[@]}"; do
    if [[ ! -r "${conf}" ]]; then has_existing_configs=false; fi
  done

  if ${has_existing_configs}; then
    ::ok "using existing configuration"
  else
    ::warn "no existing configuration"

    if [[ ! -d "${BUT__SUITECACHE}" ]]; then
      mkdir -p "${BUT__SUITECACHE}"
    fi
    if [[ ! -f "${BUT__TESTCACHE}" ]]; then
      mkdir -p "${BUT__TESTCACHE}"
    fi

    ::info "extracting environment variables from configuration"
    local config_envs
    config_envs="$(
      echo \
        "$(jq -r '.tmp?' "${config}")" \
        "$(jq -r '.env?' "${config}")" |
        jq -s add
    )"
    ::ok "environment variables extracted"
    ::debug "${config_envs}" "json"

    ::info "writing test .env file to ${BUT__ENVFILE}"
    echo "${config_envs}" | jq -r '. | keys[] as $key | $key+"="+"\""+(.[$key]|tostring)+"\""' >"${BUT__ENVFILE}"
    ::ok ".env file written"
    ::debug "${BUT__ENVFILE}" "file"
  fi

  ::info "sourcing .env file"
  # shellcheck disable=SC1090
  set -a && source "${BUT__ENVFILE}" && set +a
  ::ok ".env file sourced"
}
####################################################################################
# test suite validation
####################################################################################
::validate_suite() {
  local -r suite_source="${1:?"Require a test source string"}"

  ::info "validating source path string"
  if [[ -z "${suite_source}" ]]; then
    ::err "Invalid tests suite. Test suite file(s) MUST be a non-empty string."
    exit ${ERR_INVALID_SUITE}
  fi
  ::info "checking for shebang"
  if head -n 1 "${suite_source}" | grep -q '#!'; then
    ::err "Invalid tests suite. Test suite file(s) MUST NOT contain a shebang"
    exit ${ERR_INVALID_SUITE}
  fi
  ::info "checking permission bits"
  if gstat -c '%A' "${suite_source}" | grep -q 'x'; then
    ::err "Invalid tests suite. Test file(s) MUST NOT be executable"
    exit ${ERR_INVALID_SUITE}
  fi
  ::info "checking source contents"
  if [[ -z "$(cat "${suite_source}")" ]]; then
    ::err "Invalid tests suite. Test file(s) MUST NOT be empty"
    exit ${ERR_INVALID_SUITE}
  fi
}
####################################################################################
# test preparation
####################################################################################
::prepare_suite_tests() {
  local test="${1:?"Require a test function string"}"
  local source="${2:?"Require a source string"}"
  local before_each="${3:-}"
  local after_each="${4:-}"
  local -a negated_test_fns=("${@:4}")

  local negated="false"
  for fn in "${negated_test_fns[@]}"; do
    if [[ "${fn}" == "${test}" ]]; then
      negated="true"
    fi
  done

  local desc
  desc="$(echo "${test}" | gsed 's/_/ /g' | gsed 's/^\(test\|ntest\) //g')"

  tee "${BUT__TESTCACHE}/${test}.json" <<EOF
{
  "test": "${test}",
  "desc": "${desc^}",
  "source": "${source}",
  "before_each": "${before_each}",
  "after_each": "${after_each}",
  "negated": ${negated}
}
EOF
}
####################################################################################
# test suite preparation
####################################################################################
::prepare_suite() {
  local suite_source="${1:?"Require a suite source string"}"

  if [[ -z "${suite_source}" ]]; then
    ::err "Invalid tests suite."
    exit ${ERR_INVALID_CONFIG}
  fi

  ::info "getting suite metadata"
  local meta
  # shellcheck disable=SC1090
  meta=$(bash -c ". ${suite_source}; typeset -f")
  if [[ -z "${meta}" ]]; then
    ::err "Invalid suite source"
    ::warn "'but' suite files must be a valid bash script"
    exit ${ERR_INVALID_SUITE}
  fi
  ::ok "got suite metadata"

  ::info "getting suite tests"
  local -a test_fns=($(echo "${meta}" | grep -E '^(test|ntest)' | gsed 's/...$//g' | gsed 's/.$//g'))
  local -a negated_test_fns=($(echo "${meta}" | grep '^ntest' | gsed 's/...$//g' | gsed 's/.$//g'))
  if [[ "${#test_fns[@]}" -eq 0 ]]; then
    ::err "suite source ${suite_source} has no test functions"
    ::log::warn "functions intended as tests MUST be prefixed with 'test' or 'ntest'"
    exit ${ERR_INVALID_SUITE}
  fi
  ::ok "got suite tests"

  ::info "getting suite before hook"
  local before="::noop"
  if echo "${meta}" | grep -q '__before__'; then
    before="__before__"
    ::ok "found suite before hook"
  else
    ::warn "no suite before hook"
  fi

  ::info "getting suite after hook"
  local after="::noop"
  if echo "${meta}" | grep -q '__after__'; then
    after="__after__"
    ::ok "found suite after hook"
  else
    ::warn "no suite after hook"
  fi

  ::info "getting suite before_each hook"
  local before_each="::noop"
  if echo "${meta}" | grep -q '__before_each__'; then
    before_each="__before_each__"
    ::ok "found suite before_each hook"
  else
    ::warn "no suite before_each hook"
  fi

  ::info "getting suite after_each hook"
  local after_each="::noop"
  if echo "${meta}" | grep -q '__after_each__'; then
    after_each="__after_each__"
    ::ok "found suite after_each hook"
  else
    ::warn "no suite after_each hook"
  fi

  ::info "getting suite name"
  local name
  name="$(basename "${suite_source%.but}")"
  ::ok "suite ${name} ready"

  local -i test_count=0
  local -a tests=()

  ::info "preparing suite tests"
  for fn in "${test_fns[@]}"; do
    tests[test_count]="${fn}"
    test_count=$((test_count + 1))
    ::prepare_suite_tests "${fn}" "${suite_source}" "${before_each}" "${after_each}" "${negated_test_fns[@]}"
  done
  ::ok "${test_count} suite tests prepared"

  ::info "writing suite config to disk"
  tee "${BUT__SUITECACHE}/${name}.json" <<EOF
{
  "name": "${name}",
  "source": "${suite_source}",
  "before": "${before}",
  "after": "${after}",
  "before_each": "${before_each}",
  "after_each": "${after_each}",
  "tests": [
    $(
    index=0
    for test in "${tests[@]}"; do
      index=$((index + 1))
      printf '\t"%s"'$(if [[ "${index}" -lt "${#tests[@]}" ]]; then echo ","; fi)' \n' "${test}"
    done
  )
  ],
  "total_tests": "${test_count}"
}
EOF
  ::ok "suite config done"
}
####################################################################################
# test runner function
####################################################################################
::run_test() {
  ::info "preparing test run"
  local -i test_index="${1:?"Require a test index number"}"
  local test_json="${2:?"Require a test JSON payload string"}"
  local test_desc
  local test_negated
  local test_fn
  local test_source
  local test_before_each
  local test_after_each
  local test_status
  test_desc="$(echo "${test_json}" | jq -r '.desc')"
  test_negated="$(echo "${test_json}" | jq -r '.negated')"
  test_source="$(echo "${test_json}" | jq -r '.source')"
  test_fn="$(echo "${test_json}" | jq -r '.test')"
  test_before_each="$(echo "${test_json}" | jq -r '.before_each')"
  test_after_each="$(echo "${test_json}" | jq -r '.after_each')"
  test_status=1
  ::ok "test prepared"

  ::info "running __before_each__ hook"
  if ::is_verbose; then
    eval "${test_before_each}" || true
  else
    eval "${test_before_each}" &>/dev/null || true
  fi
  ::ok "__before_each__ hook complete"

  ::info "running test '${test_fn}' ${test_index}/${#tests[@]}"
  if ::is_verbose; then
    if eval "${test_fn}"; then test_status=0; fi
  else
    if eval "${test_fn}" &>/dev/null; then test_status=0; fi
  fi
  ::ok "test run complete"

  ::info "running __after_each__ hook"
  if ::is_verbose; then
    eval "${test_after_each}" || true
  else
    eval "${test_after_each}" &>/dev/null || true
  fi
  ::ok "__after_each__ hook complete"

  if [[ "$test_negated" == true ]]; then
    if [[ "${test_status}" -eq 0 ]]; then test_status=1; else test_status=0; fi
  fi

  if [[ ${test_status} -eq 0 ]]; then
    ::ok "test passed"
  else
    ::warn "test failed"
  fi

  ::tap "${test_status}" "${test_index}" "${test_desc}"
  if ::is_json; then echo '{
    "id": '"${test_index}"',
    "description": "'"${test_desc}"'",
    "function": "'"${test_fn}"'",
    "passed": '$(if [[ ${test_status} == 0 ]]; then echo "true"; else echo "false"; fi)'
  }' | jq -r .; fi
}

::run_tests() {
  local -i total_tests=0
  local -i suite_index=0
  local -a suites=()

  ::info "getting test suites from ${BUT__TEST_ROOT}"
  # shellcheck disable=SC2061
  if [[ -z $(find "${BUT__TEST_ROOT}" -name *.but) ]]; then
    ::err "no test found at ${BUT__TEST_ROOT}"
    ::warn "tests must have the '.but' extension"
    exit 2
  fi
  ::ok "test suites found"

  ::info "validating and preparing test suites"
  for src in "${BUT__TEST_ROOT}"/*.but; do
    ::validate_suite "${src}"
    ::info "preparing suite"
    ::prepare_suite "${src}"
    ::ok "suite prepared"
    local name
    name="$(basename "${src%.but}")"
    local suite
    suite="$(jq -r . "${BUT__SUITECACHE}/${name}.json")"
    total_tests=$(echo "${suite}" | jq -r '.total_tests')
    suites["${suite_index}"]="${suite}"
    suite_index=$((suite_index + 1))
  done
  ::ok "all suites validated and prepared"

  ::info "checking suite count"
  if [[ ${suite_index} -eq 0 ]]; then
    ::tap_start 0
    ::tap_end 0 0
    ::warn "no tests to run"
    return 0
  fi
  ::ok "valid number of suites"

  ::info "running ${suite_index} suite(s)"
  ::tap_start "${total_tests}"

  suite_index=0
  local -i test_index=0
  local -a failed_tests=()

  for suite in "${suites[@]}"; do
    ::info "getting suite tests"
    local name source before after before_each after_each
    local -a tests
    name="$(echo "${suite}" | jq -r .name)"
    source="$(echo "${suite}" | jq -r .source)"
    tests=($(echo "${suite}" | jq -r .tests[]))
    before="$(echo "${suite}" | jq -r .before)"
    after="$(echo "${suite}" | jq -r .after)"
    before_each="$(echo "${suite}" | jq -r .before_each)"
    after_each="$(echo "${suite}" | jq -r .after_each)"
    suite_index=$((suite_index + 1))
    ::ok "got suite '${name}' tests"
    ::debug "${tests[@]}"

    ::info "sourcing suite file"
    # shellcheck disable=SC1090
    source "${source}"

    if [[ -n "${before}" ]]; then
      ::ok "running before hook"
      eval "${before}"
    else
      ::warn "no before hook"
    fi
    local test
    for test_name in "${tests[@]}"; do
      ::info "configuring test ${test_name}"
      test="$(jq -r . "${BUT__TESTCACHE}/${test_name}.json")"
      ::ok "${test_name} configured"
      ::debug "${test}"
      ::info "running suite '${name}' test '${test_name}'"
      if ! ::run_test ${test_index} "${test}"; then
        failed_tests[${#failed_tests[@]}]=${test_index}
      fi
      test_index=$((test_index + 1))
    done
    if [[ -n "${after}" ]]; then
      ::ok "running after hook"
      eval "${after}"
    else
      ::warn "no after hook"
    fi
  done

  local failed_tests_report
  if [[ "${#failed_tests[@]}" -gt 0 ]]; then
    failed_tests_report=$(::join_by ', ' "${failed_tests[@]}")
  else
    failed_tests_report=""
  fi

  ::tap_end "${test_index}" "${#failed_tests[@]}" "${failed_tests_report}"
  ::ok "all tests complete. ran ${#tests[@]}."
  if [[ "${#failed_tests[@]}" -gt 0 ]]; then
    return 1
  else
    return 0
  fi
}
####################################################################################
# execute the 'but' program
####################################################################################
but::exec() {
  ::info "running bash unit testing tool"
  ::info "using config at ${BUT__CONFIG_SRC}"

  ::info "preparing configuration"
  if ! ::source_config; then
    ::err "error preparing configuration. use but -v to get debug information"
    exit ${ERR_INVALID_CONFIG}
  fi
  ::ok "configuration prepared"

  ::ok "ready to start"
  if [[ -f "${BUT__LOCKFILE}" ]]; then
    if pgrep -q $(cat "${BUT__LOCKFILE}"); then
      ::err "tests are running in another process. parallel but instances are not supported"
      exit ${ERR_INVALID_CONFIG}
    fi
    ::warn "previous test run with PID $(cat "${BUT__LOCKFILE}") did not exit properly. removing lockfile"
    rm "${BUT__LOCKFILE}"
  fi

  ::info "locking process"
  echo $$ >>"${BUT__LOCKFILE}"

  ::info "starting test suites"
  ::run_tests
  ::ok "test suite(s) complete"
  return 0
}

####################################################################################
# run 'but' as a command call
####################################################################################
::print_help() {
  echo 'Usage: but [OPTION]...

-v, --version
        current version
--verbose
        output debug information at runtime
-t, --tap
        output TAP protocol version 13
-j, --json
        output JSON
-h, --help
        output this display help text
'
}
::confirm() {
  local response
  # shellcheck disable=SC2116
  tput setaf 227
  # shellcheck disable=SC2116
  read -s -n 1 -r -e -p "run tests from config ${BUT__CONFIG_SRC}? [Y/n] $(echo $'\n> ')" response
  tput sgr0
  if [[ "${response:-"n"}" =~ ^([yY])+$ ]]; then
    true
  else
    false
  fi
}
# translates command-line flags into the appropriate configuration
::run_as_command() {
  local option="${1-""}"
  case "${option}" in
  -v | --version)
    if [[ -r "${__root}/package.json" ]]; then
      jq -r '.version?' "${__root}/package.json"
    else
      echo "unknown"
    fi
    ;;
  --verbose)
    BUT__CONFIG_OUTPUT="verbose"
    ::confirm && but::exec
    ;;
  -t | --tap)
    BUT__CONFIG_OUTPUT="tap"
    if ::check_command "tap"; then
      ::confirm && but::exec | tap -
    else
      ::confirm && but::exec
    fi
    ;;
  -j | --json)
    BUT__CONFIG_OUTPUT="json"
    ::confirm && but::exec
    ;;
  -h | --help)
    ::print_help
    ;;
  *)
    if [[ -z "${option}" ]]; then
      ::confirm && but::exec
    else
      ::warn "option '${option}' not found"
      ::print_help
    fi
    ;;
  esac
}
# if run as a command call but and translate flags into environment variables
if [ "$0" == "${BASH_SOURCE[0]}" ]; then
  ::run_as_command "$@"
fi
