#!/usr/bin/env bash

### Created by Kiran Shila ( kiranshila ) on 2024-01-23
### Based on https://github.com/pforret/bashew 1.20.5
script_version="0.5.0" # if there is a VERSION.md in this script's folder, that will have priority over this version number
readonly script_author="me@kiranshila.com"
readonly script_created="2024-01-23"
readonly run_as_root=-1 # run_as_root: 0 = don't check anything / 1 = script MUST run as root / -1 = script MAY NOT run as root
readonly script_description="Run the GReX pipeline"
## some initialisation
action=""
script_prefix=""
script_basename=""
install_package=""
temp_files=()

function Option:config() {
  ### Change the next lines to reflect which flags/options/parameters you need
  ### flag:   switch a flag 'on' / no value specified
  ###     flag|<short>|<long>|<description>
  ###     e.g. "-v" or "--verbose" for verbose output / default is always 'off'
  ###     will be available as $<long> in the script e.g. $verbose
  ### option: set an option / 1 value specified
  ###     option|<short>|<long>|<description>|<default>
  ###     e.g. "-e <extension>" or "--extension <extension>" for a file extension
  ###     will be available a $<long> in the script e.g. $extension
  ### list: add an list/array item / 1 value specified
  ###     list|<short>|<long>|<description>| (default is ignored)
  ###     e.g. "-u <user1> -u <user2>" or "--user <user1> --user <user2>"
  ###     will be available a $<long> array in the script e.g. ${user[@]}
  ### param:  comes after the options
  ###     param|<type>|<long>|<description>
  ###     <type> = 1 for single parameters - e.g. param|1|output expects 1 parameter <output>
  ###     <type> = ? for optional parameters - e.g. param|1|output expects 1 parameter <output>
  ###     <type> = n for list parameter    - e.g. param|n|inputs expects <input1> <input2> ... <input99>
  ###     will be available as $<long> in the script after option/param parsing
  ### choice:  is like a param, but when there are limited options
  ###     choice|<type>|<long>|<description>|choice1,choice2,...
  ###     <type> = 1 for single parameters - e.g. param|1|output expects 1 parameter <output>
  grep <<< "
flag|h|help|show usage
flag|q|quiet|no output
flag|v|verbose|also show debug messages
flag|st|skip_ntp|skip NTP synchronization
flag|tg|trigger|trigger packets directly (no GPS)
option|ap|average_power|2^n for downsampling|2
option|vc|vbuf_capacity|Capacity for the voltage buffer size|8388608
option|ic|injection_cadence|time in seconds in inject fake pulses|36000
option|ip|injection_path|path to folder of fake pulses (.dat)|$script_install_folder/fake
option|vp|voltage_path|directory to save voltage dumps|/hdd/data/voltages/
option|fp|filterbank_path|directory to save filterbanks|/hdd/data/filterbanks/
option|dbp|db_path|path to SQLite database|/hdd/data/candidates.db
option|cp2|t2_cand_path|path to T2 intermediate candidates|/hdd/data/candidates/T2/
option|ds|dm_start|lower limit DM of search|20
option|de|dm_end|upper limit DM of search|1000
option|bm|boxcar_max|largest boxcar size to use in heimdall|32
option|f|gateware|gateware file|$script_install_folder/../t0/gateware/grex_gateware.fpg
option|t0|t0_path|path to t0 executable|$script_install_folder/../t0/target/release/grex_t0
option|cr|clean_rfi_path|path to clean_rfi executable|$script_install_folder/../clean_rfi/target/release/clean_rfi
option|t2|t2_path|path to t2 folder|$script_install_folder/../t2
option|sb|snap_bringup_path|path to snap bringup python script|$script_install_folder/../snap_bringup
option|dg|digital_gain|digital gain for the ADC|4
option|rg|requant_gain|set a fixed requantization gain|40
option|fa|fem_atten|set the FEM attenuation level|5
option|d|samples|Number of samples in each DADA block|65536
option|rfit|rfi_time_thresh|Sigma cut threshold for RFI excision in time|5
option|rfif|rfi_freq_thresh|Sigma cut threshold for RFI excision in freq|5
option|s|snap|IP address of the SNAP|192.168.0.3
option|mac|mac|MAC address of the NIC we'll get packets on
option|slack|slack_url|Slack webhook url for notifications
choice|1|action|action to perform/pipeline mode|full,cand_socket,cand_file,dada,filterbank,none,check,snap_on,snap_off,snap_cycle,env,update,cleanup
" -v -e '^#' -e '^\s*$'
}

#####################################################################
## Put your Script:main script here
#####################################################################

# Some non-option constants
CHANNELS=2048
FROM_T0_KEY=b0ba
FROM_RFI_CLEANING_KEY=cafe
function Script:main() {
  IO:log "[$script_basename] $script_version started"

  Os:require "awk"

  case "${action,,}" in
    full)
      #TIP: use «$script_prefix full» to run the full FRB detection pipeline
      Os:require "parallel"
      dada_init
      set_fem_atten
      snap_init
      IO:announce "Starting T0 -> T1 -> T2 Pipeline"
      # Construct pipeline process launch commands
      t0=$(t0_cmd "psrdada -k $FROM_T0_KEY -s $samples")
      clean_rfi=$(clean_rfi_cmd)
      t1=$(t1_cmd "-coincidencer 127.0.0.1:12345")
      t2=$(t2_cmd)
      trap _int SIGINT SIGTERM
      parallel --halt now,done=1 -u ::: "$t0" "$clean_rfi" "$t1" "$t2" &
      alert_slack_up
      child=$!
      wait "$child"
      alert_slack_down
      dada_cleanup
      snap_powerdown
      ;;

    cand_file)
      #TIP: use «$script_prefix cand_file» to run the pipeline through heimdall, dumping candidates to a file
      Os:require "parallel"
      dada_init
      set_fem_atten
      snap_init
      IO:announce "Starting T0 -> T1 Candidate File Pipeline"
      # Construct pipeline process launch commands
      t0=$(t0_cmd "psrdada -k $FROM_T0_KEY -s $samples")
      clean_rfi=$(clean_rfi_cmd)
      t1=$(t1_cmd "")
      trap _int SIGINT SIGTERM
      parallel --halt now,done=1 -u ::: "$t0" "$clean_rfi" "$t1" &
      child=$!
      wait "$child"
      dada_cleanup
      snap_powerdown
      ;;

    cand_socket)
      #TIP: use «$script_prefix cand_socket» to run the pipeline through heimdall, dumping candidates to a socket
      Os:require "parallel"
      dada_init
      set_fem_atten
      snap_init
      IO:announce "Starting T0 -> T1 Candidate File Pipeline"
      # Construct pipeline process launch commands
      t0=$(t0_cmd "psrdada -k $FROM_T0_KEY -s $samples")
      clean_rfi=$(clean_rfi_cmd)
      t1=$(t1_cmd "-coincidencer 127.0.0.1:12345")
      trap _int SIGINT SIGTERM
      parallel --halt now,done=1 -u ::: "$t0" "$clean_rfi" "$t1" &
      child=$!
      wait "$child"
      dada_cleanup
      snap_powerdown
      ;;

    dada)
     #TIP: use «$script_prefix dada» to run the pipeline to fill a DADA buffer (inlcluding RFI filtering), but not starting heimdall
      Os:require "parallel"
      dada_init
      set_fem_atten
      snap_init
      IO:announce "Starting T0 -> DADA Buffer Pipeline"
      # Construct pipeline process launch commands
      t0=$(t0_cmd "psrdada -k $FROM_T0_KEY -s $samples")
      clean_rfi=$(clean_rfi_cmd)
      trap _int SIGINT SIGTERM
      parallel --halt now,done=1 -u ::: "$t0" "$clean_rfi"&
      child=$!
      wait "$child"
      dada_cleanup
      snap_powerdown
     ;;

    filterbank)
      #TIP: use «$script_prefix filterbank» to run just T0 to fill a filterbank file
      set_fem_atten
      snap_init
      IO:announce "Starting T0 -> Filterbank Pipeline"
      t0=$(t0_cmd "filterbank")
      trap _int SIGINT SIGTERM
      eval "$t0" &
      child=$!
      wait "$child"
      snap_powerdown
      ;;

    none)
      #TIP: use «$script_prefix none» to run just T0 with no exfil (only talks to Prometheus)
      set_fem_atten
      snap_init
      IO:announce "Starting T0"
      t0=$(t0_cmd "")
      trap _int SIGINT SIGTERM
      eval "$t0" &
      child=$!
      wait "$child"
      snap_powerdown
      ;;

    cleanup)
      #TIP: use «$script_prefix cleanup» to cleanup DADA buffers that were left around from a crash
      dada_cleanup
      ;;

    snap_off)
      #TIP: use «$script_prefix snap_off» to power down the SNAP
      snap_powerdown
      ;;

    snap_on)
      #TIP: use «$script_prefix snap_on» to power up the SNAP
      snap_poweron
      ;;

    snap_cycle)
      #TIP: use «$script_prefix snap_cycle» to power up the SNAP
      snap_powercycle
      ;;

    check | env)
      ## leave this default action, it will make it easier to test your script
      #TIP: use «$script_prefix check» to check if this script is ready to execute and what values the options/flags are
      #TIP:> $script_prefix check
      #TIP: use «$script_prefix env» to generate an example .env file
      #TIP:> $script_prefix env > .env
      Script:check
      ;;

    update)
      ## leave this default action, it will make it easier to test your script
      #TIP: use «$script_prefix update» to update to the latest version
      #TIP:> $script_prefix update
      Script:git_pull
      ;;

    *)
      IO:die "action [$action] not recognized"
      ;;
  esac
  IO:log "[$script_basename] ended after $SECONDS secs"
}

#####################################################################
## Put your helper scripts here
#####################################################################

_int() { 
  IO:debug "Caught signal!" 
  kill -INT "$child" 2>/dev/null
}

function snap_powerup() {
  IO:announce "Powering up SNAP"
  ssh pi "./snap.sh on"
}

function snap_powerdown() {
  IO:announce "Powering down SNAP"
  ssh pi "./snap.sh off"
}

function snap_powercycle() {
  IO:announce "Power cycling SNAP"
  ssh pi "./snap.sh off"
  ssh pi "./snap.sh on"
}

function set_fem_atten() {
  IO:announce "Setting the FEM attenuation"
  ssh pi "./cli /dev/ttyAMA0 atten $fem_atten"
}

function snap_init() {
  IO:announce "Initializing SNAP"
  Os:require "poetry" "pipx install poetry"
  snap_powercycle
  # Doing it like this because we want the subshell for the path of poetry to work
  eval "cd $snap_bringup_path; poetry run snap_bringup $gateware $snap --gain=$digital_gain; cd -"
}

function dada_init() {
  IO:announce "Setting up PSRDADA buffers"
  dada_db -k $FROM_T0_KEY -b $((CHANNELS*samples*4)) -l -p -n 8
  dada_db -k $FROM_RFI_CLEANING_KEY -b $((CHANNELS*samples*4)) -l -p -n 8
}

function dada_cleanup() {
  IO:announce "Cleaning up PSRDADA buffers"
  dada_db -k $FROM_T0_KEY -d
  dada_db -k $FROM_RFI_CLEANING_KEY -d
}

function alert_slack_up() {
  Os:require "curl"
  curl \
    --silent \
    --output /dev/null \
    -X POST \
    -H 'Content-Type: application/json' \
    --data "{\"username\": \"Pipeline Alerts\", \"attachments\": [{\"color\": \"good\",\"title\": \"Pipeline started on ${HOSTNAME}\"}]}" \
    ${slack_url}
}

function alert_slack_down() {
  Os:require "curl"
  curl \
    --silent \
    --output /dev/null \
    -X POST \
    -H 'Content-Type: application/json' \
    --data "{\"username\": \"Pipeline Alerts\", \"attachments\": [{\"color\": \"danger\",\"title\": \"Pipeline stopped on ${HOSTNAME}\"}]}" \
    ${slack_url}
}

## Pipeline stage execution builders

function t0_cmd() {
  ntp_flag=""
  if [ "$skip_ntp" = "1" ]; then
    ntp_flag="--skip-ntp"
  fi

  trigger_flag=""
  if [ "$trigger" = "1" ]; then
    trigger_flag="--trig"
  fi

  requant_option=""
  if [ -n "$requant_gain" ]; then
    requant_option="--requant-gain $requant_gain"
  fi

  echo -e "RUST_LOG=info $t0_path \
    -d $average_power \
    --vbuf-capacity $vbuf_capacity \
    $ntp_flag \
    $trigger_flag \
    $requant_option \
    --fpga-addr $snap:69 \
    --injection-cadence $injection_cadence \
    --pulse-path $injection_path \
    --dump-path $voltage_path \
    --db-path $db_path \
    --mac $mac \
    --filterbank-path $filterbank_path $1"
}

function clean_rfi_cmd() {
  Os:require "taskset" "util-linux"
  echo -e "taskset -c 8 $clean_rfi_path -f $rfi_freq_thresh -s $rfi_time_thresh  dada -f $FROM_T0_KEY -t $FROM_RFI_CLEANING_KEY"
}

function t1_cmd() {
  Os:require "taskset" "util-linux"
  Os:require "grep"

  echo -e "taskset -c 9 \
    heimdall -k $FROM_RFI_CLEANING_KEY \
    -gpu_id 0 \
    -nsamps_gulp $samples \
    -nbeams 1 \
    -dm_tol 1.50 \
    -boxcar_max $boxcar_max \
    -dm $dm_start $dm_end \
    -scrunching 0 $1"
}

function t2_cmd() {
  Os:require "poetry" "pipx install poetry"
  Os:require "taskset" "util-linux"
  echo -e "cd $t2_path; taskset -c 10-14 poetry run startT2 --outroot $t2_cand_path --db-path $db_path"
}

#####################################################################
################### DO NOT MODIFY BELOW THIS LINE ###################
#####################################################################

# set strict mode -  via http://redsymbol.net/articles/unofficial-bash-strict-mode/
# removed -e because it made basic [[ testing ]] difficult
set -uo pipefail
IFS=$'\n\t'
force=0
help=0
error_prefix=""

#to enable verbose even before option parsing
verbose=0
[[ $# -gt 0 ]] && [[ $1 == "-v" ]] && verbose=1

#to enable quiet even before option parsing
quiet=0
[[ $# -gt 0 ]] && [[ $1 == "-q" ]] && quiet=1

txtReset=""
txtError=""
txtInfo=""
txtInfo=""
txtWarn=""
txtBold=""
txtItalic=""
txtUnderline=""

char_succes="OK "
char_fail="!! "
char_alert="?? "
char_wait="..."
info_icon="(i)"
config_icon="[c]"
clean_icon="[c]"
require_icon="[r]"

### stdIO:print/stderr output
function IO:initialize() {
  script_started_at="$(Tool:time)"
  IO:debug "script $script_basename started at $script_started_at"

  [[ "${BASH_SOURCE[0]:-}" != "${0}" ]] && sourced=1 || sourced=0
  [[ -t 1 ]] && piped=0 || piped=1 # detect if output is piped
  if [[ $piped -eq 0 ]]; then
    txtReset=$(tput sgr0)
    txtError=$(tput setaf 160)
    txtInfo=$(tput setaf 2)
    txtWarn=$(tput setaf 214)
    txtBold=$(tput bold)
    txtItalic=$(tput sitm)
    txtUnderline=$(tput smul)
  fi

  [[ $(echo -e '\xe2\x82\xac') == '€' ]] && unicode=1 || unicode=0 # detect if unicode is supported
  if [[ $unicode -gt 0 ]]; then
    char_succes="✅"
    char_fail="⛔"
    char_alert="✴️"
    char_wait="⏳"
    info_icon="🌼"
    config_icon="🌱"
    clean_icon="🧽"
    require_icon="🔌"
  fi
  error_prefix="${txtError}>${txtReset}"
}

function IO:print() {
  ((quiet)) && true || printf '%b\n' "$*"
}

function IO:debug() {
  ((verbose)) && IO:print "${txtInfo}# $* ${txtReset}" >&2
  true
}

function IO:die() {
  IO:print "${txtError}${char_fail} $script_basename${txtReset}: $*" >&2
  tput bel
  Script:exit
}

function IO:alert() {
  IO:print "${txtWarn}${char_alert}${txtReset}: ${txtUnderline}$*${txtReset}" >&2
}

function IO:success() {
  IO:print "${txtInfo}${char_succes}${txtReset}  ${txtBold}$*${txtReset}"
}

function IO:announce() {
  IO:print "${txtInfo}${char_wait}${txtReset}  ${txtItalic}$*${txtReset}"
  sleep 1
}

function IO:progress() {
  ((quiet)) || (
    local screen_width
    screen_width=$(tput cols 2> /dev/null || echo 80)
    local rest_of_line
    rest_of_line=$((screen_width - 5))

    if ((piped)); then
      IO:print "... $*" >&2
    else
      printf "... %-${rest_of_line}b\r" "$*                                             " >&2
    fi
  )
}

function IO:countdown() {
  local seconds=${1:-5}
  local message=${2:-Countdown :}

  if ((piped)); then
    IO:print "$message $seconds seconds"
  else
    for ((i = 0; i < "$seconds"; i++)); do
      IO:progress "${txtInfo}$message $((seconds - i)) seconds${txtReset}"
      sleep 1
    done
    IO:print "                         "
  fi
}

### interactive
function IO:confirm() {
  ((force)) && return 0
  read -r -p "$1 [y/N] " -n 1
  echo " "
  [[ $REPLY =~ ^[Yy]$ ]]
}

function IO:question() {
  local ANSWER
  local DEFAULT=${2:-}
  read -r -p "$1 ($DEFAULT) > " ANSWER
  [[ -z "$ANSWER" ]] && echo "$DEFAULT" || echo "$ANSWER"
}

function IO:log() {
  [[ -n "${log_file:-}" ]] && echo "$(date '+%H:%M:%S') | $*" >> "$log_file"
}

function Tool:calc() {
  awk "BEGIN {print $*} ; "
}

function Tool:round() {
  local number="${1}"
  local decimals="${2:-0}"

  awk "BEGIN {print sprintf( \"%.${decimals}f\" , $number )};"
}

function Tool:time() {
  if [[ $(command -v perl) ]]; then
    perl -MTime::HiRes=time -e 'printf "%f\n", time'
  elif [[ $(command -v php) ]]; then
    php -r 'printf("%f\n",microtime(true));'
  elif [[ $(command -v python) ]]; then
    python -c 'import time; print(time.time()) '
  elif [[ $(command -v python3) ]]; then
    python3 -c 'import time; print(time.time()) '
  elif [[ $(command -v node) ]]; then
    node -e 'console.log(+new Date() / 1000)'
  elif [[ $(command -v ruby) ]] ; then
    ruby -e 'STDOUT.puts(Time.now.to_f)'
  else
    date '+%s.000'
  fi
}

function Tool:throughput() {
  local time_started="$1"
  [[ -z "$time_started" ]] && time_started="$script_started_at"
  local operations="${2:-1}"
  local name="${3:-operation}"

  local time_finished
  local duration
  local seconds
  time_finished="$(Tool:time)"
  duration="$(Tool:calc "$time_finished - $time_started")"
  seconds="$(Tool:round "$duration")"
  if [[ "$operations" -gt 1 ]] ; then
    if [[ $operations -gt $seconds ]] ; then
      ops=$(Tool:calc "$operations / $duration" )
      ops=$(Tool:round "$ops" 3)
      duration=$(Tool:round "$duration" 2)
      IO:print "$operations $name finished in $duration secs: $ops $name/sec"
    else
      ops=$(Tool:calc "$duration / $operations" )
      ops=$(Tool:round "$ops" 3)
      duration=$(Tool:round "$duration" 2)
      IO:print "$operations $name finished in $duration secs: $ops sec/$name"
    fi
  else
    duration=$(Tool:round "$duration" 2)
    IO:print "$name finished in $duration secs"
  fi
}

### string processing

function Str:trim() {
  local var="$*"
  # remove leading whitespace characters
  var="${var#"${var%%[![:space:]]*}"}"
  # remove trailing whitespace characters
  var="${var%"${var##*[![:space:]]}"}"
  printf '%s' "$var"
}

function Str:lower() {
  if [[ -n "$1" ]]; then
    local input="$*"
    echo "${input,,}"
  else
    awk '{print tolower($0)}'
  fi
}

function Str:upper() {
  if [[ -n "$1" ]]; then
    local input="$*"
    echo "${input^^}"
  else
    awk '{print toupper($0)}'
  fi
}

function Str:ascii() {
  # remove all characters with accents/diacritics to latin alphabet
  # shellcheck disable=SC2020
  sed 'y/àáâäæãåāǎçćčèéêëēėęěîïííīįìǐłñńôöòóœøōǒõßśšûüǔùǖǘǚǜúūÿžźżÀÁÂÄÆÃÅĀǍÇĆČÈÉÊËĒĖĘĚÎÏÍÍĪĮÌǏŁÑŃÔÖÒÓŒØŌǑÕẞŚŠÛÜǓÙǕǗǙǛÚŪŸŽŹŻ/aaaaaaaaaccceeeeeeeeiiiiiiiilnnooooooooosssuuuuuuuuuuyzzzAAAAAAAAACCCEEEEEEEEIIIIIIIILNNOOOOOOOOOSSSUUUUUUUUUUYZZZ/'
}

function Str:slugify() {
  # Str:slugify <input> <separator>
  # Str:slugify "Jack, Jill & Clémence LTD"      => jack-jill-clemence-ltd
  # Str:slugify "Jack, Jill & Clémence LTD" "_"  => jack_jill_clemence_ltd
  separator="${2:-}"
  [[ -z "$separator" ]] && separator="-"
  Str:lower "$1" |
    Str:ascii |
    awk '{
          gsub(/[\[\]@#$%^&*;,.:()<>!?\/+=_]/," ",$0);
          gsub(/^  */,"",$0);
          gsub(/  *$/,"",$0);
          gsub(/  */,"-",$0);
          gsub(/[^a-z0-9\-]/,"");
          print;
          }' |
    sed "s/-/$separator/g"
}

function Str:title() {
  # Str:title <input> <separator>
  # Str:title "Jack, Jill & Clémence LTD"     => JackJillClemenceLtd
  # Str:title "Jack, Jill & Clémence LTD" "_" => Jack_Jill_Clemence_Ltd
  separator="${2:-}"
  # shellcheck disable=SC2020
  Str:lower "$1" |
    tr 'àáâäæãåāçćčèéêëēėęîïííīįìłñńôöòóœøōõßśšûüùúūÿžźż' 'aaaaaaaaccceeeeeeeiiiiiiilnnoooooooosssuuuuuyzzz' |
    awk '{ gsub(/[\[\]@#$%^&*;,.:()<>!?\/+=_-]/," ",$0); print $0; }' |
    awk '{
          for (i=1; i<=NF; ++i) {
              $i = toupper(substr($i,1,1)) tolower(substr($i,2))
          };
          print $0;
          }' |
    sed "s/ /$separator/g" |
    cut -c1-50
}

function Str:digest() {
  local length=${1:-6}
  if [[ -n $(command -v md5sum) ]]; then
    # regular linux
    md5sum | cut -c1-"$length"
  else
    # macos
    md5 | cut -c1-"$length"
  fi
}

# Gha: function should only be run inside of a Github Action

function Gha:finish() {
  [[ -z "${RUNNER_OS:-}" ]] && IO:die "This should only run inside a Github Action, don't run it on your machine"
  git config user.name "Bashew Runner"
  git config user.email "actions@users.noreply.github.com"
  timestamp=$(date -u)
  message="$timestamp < $script_basename $script_version"
  git add -A
  git commit -m "${message}" || exit 0
  git pull --rebase
  git push
  exit 0
}

trap "IO:die \"ERROR \$? after \$SECONDS seconds \n\
\${error_prefix} last command : '\$BASH_COMMAND' \" \
\$(< \$script_install_path awk -v lineno=\$LINENO \
'NR == lineno {print \"\${error_prefix} from line \" lineno \" : \" \$0}')" INT TERM EXIT
# cf https://askubuntu.com/questions/513932/what-is-the-bash-command-variable-good-for

Script:exit() {
  for temp_file in "${temp_files[@]-}"; do
    [[ -f "$temp_file" ]] && (
      IO:debug "Delete temp file [$temp_file]"
      rm -f "$temp_file"
    )
  done
  trap - INT TERM EXIT
  IO:debug "$script_basename finished after $SECONDS seconds"
  exit 0
}

Script:check_version() {
  (
    # shellcheck disable=SC2164
    pushd "$script_install_folder" &> /dev/null
    if [[ -d .git ]]; then
      local remote
      remote="$(git remote -v | grep fetch | awk 'NR == 1 {print $2}')"
      IO:progress "Check for latest version - $remote"
      git remote update &> /dev/null
      if [[ $(git rev-list --count "HEAD...HEAD@{upstream}" 2> /dev/null) -gt 0 ]]; then
        IO:print "There is a more recent update of this script - run <<$script_prefix update>> to update"
      fi
    fi
    # shellcheck disable=SC2164
    popd &> /dev/null
  )
}

Script:git_pull() {
  # run in background to avoid problems with modifying a running interpreted script
  (
    sleep 1
    cd "$script_install_folder" && git pull
  ) &
}

Script:show_tips() {
  ((sourced)) && return 0
  # shellcheck disable=SC2016
  grep < "${BASH_SOURCE[0]}" -v '$0' |
    awk \
      -v green="$txtInfo" \
      -v yellow="$txtWarn" \
      -v reset="$txtReset" \
      '
      /TIP: /  {$1=""; gsub(/«/,green); gsub(/»/,reset); print "*" $0}
      /TIP:> / {$1=""; print " " yellow $0 reset}
      ' |
    awk \
      -v script_basename="$script_basename" \
      -v script_prefix="$script_prefix" \
      '{
      gsub(/\$script_basename/,script_basename);
      gsub(/\$script_prefix/,script_prefix);
      print ;
      }'
}

Script:check() {
  local name
  if [[ -n $(Option:filter flag) ]]; then
    IO:print "## ${txtInfo}boolean flags${txtReset}:"
    Option:filter flag |
      while read -r name; do
        declare -p "$name" | cut -d' ' -f3-
      done
  fi

  if [[ -n $(Option:filter option) ]]; then
    IO:print "## ${txtInfo}option defaults${txtReset}:"
    Option:filter option |
      while read -r name; do
        declare -p "$name" | cut -d' ' -f3-
      done
  fi

  if [[ -n $(Option:filter list) ]]; then
    IO:print "## ${txtInfo}list options${txtReset}:"
    Option:filter list |
      while read -r name; do
        declare -p "$name" | cut -d' ' -f3-
      done
  fi

  if [[ -n $(Option:filter param) ]]; then
    if ((piped)); then
      IO:debug "Skip parameters for .env files"
    else
      IO:print "## ${txtInfo}parameters${txtReset}:"
      Option:filter param |
        while read -r name; do
          declare -p "$name" | cut -d' ' -f3-
        done
    fi
  fi

  if [[ -n $(Option:filter choice) ]]; then
    if ((piped)); then
      IO:debug "Skip choices for .env files"
    else
      IO:print "## ${txtInfo}choice${txtReset}:"
      Option:filter choice |
        while read -r name; do
          declare -p "$name" | cut -d' ' -f3-
        done
    fi
  fi

  IO:print "## ${txtInfo}required commands${txtReset}:"
  Script:show_required
}

Option:usage() {
  IO:print "Program : ${txtInfo}$script_basename${txtReset}  by ${txtWarn}$script_author${txtReset}"
  IO:print "Version : ${txtInfo}v$script_version${txtReset} (${txtWarn}$script_modified${txtReset})"
  IO:print "Purpose : ${txtInfo}$script_description${txtReset}"
  echo -n  "Usage   : $script_basename"
  Option:config |
    awk '
  BEGIN { FS="|"; OFS=" "; oneline="" ; fulltext="Flags, options and parameters:"}
  $1 ~ /flag/  {
    fulltext = fulltext sprintf("\n    -%1s|--%-12s: [flag] %s [default: off]",$2,$3,$4) ;
    oneline  = oneline " [-" $2 "]"
    }
  $1 ~ /option/  {
    fulltext = fulltext sprintf("\n    -%1s|--%-12s: [option] %s",$2,$3 " <?>",$4) ;
    if($5!=""){fulltext = fulltext "  [default: " $5 "]"; }
    oneline  = oneline " [-" $2 " <" $3 ">]"
    }
  $1 ~ /list/  {
    fulltext = fulltext sprintf("\n    -%1s|--%-12s: [list] %s (array)",$2,$3 " <?>",$4) ;
    fulltext = fulltext "  [default empty]";
    oneline  = oneline " [-" $2 " <" $3 ">]"
    }
  $1 ~ /secret/  {
    fulltext = fulltext sprintf("\n    -%1s|--%s <%s>: [secret] %s",$2,$3,"?",$4) ;
      oneline  = oneline " [-" $2 " <" $3 ">]"
    }
  $1 ~ /param/ {
    if($2 == "1"){
          fulltext = fulltext sprintf("\n    %-17s: [parameter] %s","<"$3">",$4);
          oneline  = oneline " <" $3 ">"
     }
     if($2 == "?"){
          fulltext = fulltext sprintf("\n    %-17s: [parameter] %s (optional)","<"$3">",$4);
          oneline  = oneline " <" $3 "?>"
     }
     if($2 == "n"){
          fulltext = fulltext sprintf("\n    %-17s: [parameters] %s (1 or more)","<"$3">",$4);
          oneline  = oneline " <" $3 " …>"
     }
    }
  $1 ~ /choice/ {
        fulltext = fulltext sprintf("\n    %-17s: [choice] %s","<"$3">",$4);
        if($5!=""){fulltext = fulltext "  [options: " $5 "]"; }
        oneline  = oneline " <" $3 ">"
    }
    END {print oneline; print fulltext}
  '
}

function Option:filter() {
  Option:config | grep "$1|" | cut -d'|' -f3 | sort | grep -v '^\s*$'
}

function Script:show_required() {
  grep 'Os:require' "$script_install_path" |
    grep -v -E '\(\)|grep|# Os:require' |
    awk -v install="# $install_package " '
    function ltrim(s) { sub(/^[ "\t\r\n]+/, "", s); return s }
    function rtrim(s) { sub(/[ "\t\r\n]+$/, "", s); return s }
    function trim(s) { return rtrim(ltrim(s)); }
    NF == 2 {print install trim($2); }
    NF == 3 {print install trim($3); }
    NF > 3  {$1=""; $2=""; $0=trim($0); print "# " trim($0);}
  ' |
    sort -u
}

function Option:initialize() {
  local init_command
  init_command=$(Option:config |
    grep -v "verbose|" |
    awk '
    BEGIN { FS="|"; OFS=" ";}
    $1 ~ /flag/   && $5 == "" {print $3 "=0; "}
    $1 ~ /flag/   && $5 != "" {print $3 "=\"" $5 "\"; "}
    $1 ~ /option/ && $5 == "" {print $3 "=\"\"; "}
    $1 ~ /option/ && $5 != "" {print $3 "=\"" $5 "\"; "}
    $1 ~ /choice/   {print $3 "=\"\"; "}
    $1 ~ /list/     {print $3 "=(); "}
    $1 ~ /secret/   {print $3 "=\"\"; "}
    ')
  if [[ -n "$init_command" ]]; then
    eval "$init_command"
  fi
}

function Option:has_single() { Option:config | grep 'param|1|' > /dev/null; }
function Option:has_choice() { Option:config | grep 'choice|1' > /dev/null; }
function Option:has_optional() { Option:config | grep 'param|?|' > /dev/null; }
function Option:has_multi() { Option:config | grep 'param|n|' > /dev/null; }

function Option:parse() {
  if [[ $# -eq 0 ]]; then
    Option:usage >&2
    Script:exit
  fi

  ## first process all the -x --xxxx flags and options
  while true; do
    # flag <flag> is saved as $flag = 0/1
    # option <option> is saved as $option
    if [[ $# -eq 0 ]]; then
      ## all parameters processed
      break
    fi
    if [[ ! $1 == -?* ]]; then
      ## all flags/options processed
      break
    fi
    local save_option
    save_option=$(Option:config |
      awk -v opt="$1" '
        BEGIN { FS="|"; OFS=" ";}
        $1 ~ /flag/   &&  "-"$2 == opt {print $3"=1"}
        $1 ~ /flag/   && "--"$3 == opt {print $3"=1"}
        $1 ~ /option/ &&  "-"$2 == opt {print $3"=${2:-}; shift"}
        $1 ~ /option/ && "--"$3 == opt {print $3"=${2:-}; shift"}
        $1 ~ /list/ &&  "-"$2 == opt {print $3"+=(${2:-}); shift"}
        $1 ~ /list/ && "--"$3 == opt {print $3"=(${2:-}); shift"}
        $1 ~ /secret/ &&  "-"$2 == opt {print $3"=${2:-}; shift #noshow"}
        $1 ~ /secret/ && "--"$3 == opt {print $3"=${2:-}; shift #noshow"}
        ')
    if [[ -n "$save_option" ]]; then
      if echo "$save_option" | grep shift >> /dev/null; then
        local save_var
        save_var=$(echo "$save_option" | cut -d= -f1)
        IO:debug "$config_icon parameter: ${save_var}=$2"
      else
        IO:debug "$config_icon flag: $save_option"
      fi
      eval "$save_option"
    else
      IO:die "cannot interpret option [$1]"
    fi
    shift
  done

  ((help)) && (
    Option:usage
    Script:check_version
    IO:print "                                  "
    echo "### TIPS & EXAMPLES"
    Script:show_tips

  ) && Script:exit

  local option_list
  local option_count
  local choices
  local single_params
  ## then run through the given parameters
  if Option:has_choice; then
    choices=$(Option:config | awk -F"|" '
      $1 == "choice" && $2 == 1 {print $3}
      ')
    option_list=$(xargs <<< "$choices")
    option_count=$(wc <<< "$choices" -w | xargs)
    IO:debug "$config_icon Expect : $option_count choice(s): $option_list"
    [[ $# -eq 0 ]] && IO:die "need the choice(s) [$option_list]"

    local choices_list
    local valid_choice
    for param in $choices; do
      [[ $# -eq 0 ]] && IO:die "need choice [$param]"
      [[ -z "$1" ]] && IO:die "need choice [$param]"
      IO:debug "$config_icon Assign : $param=$1"
      # check if choice is in list
      choices_list=$(Option:config | awk -F"|" -v choice="$param" '$1 == "choice" && $3 = choice {print $5}')
      valid_choice=$(tr <<< "$choices_list" "," "\n" | grep "$1")
      [[ -z "$valid_choice" ]] && IO:die "choice [$1] is not valid, should be in list [$choices_list]"

      eval "$param=\"$1\""
      shift
    done
  else
    IO:debug "$config_icon No choices to process"
    choices=""
    option_count=0
  fi

  if Option:has_single; then
    single_params=$(Option:config | awk -F"|" '
      $1 == "param" && $2 == 1 {print $3}
      ')
    option_list=$(xargs <<< "$single_params")
    option_count=$(wc <<< "$single_params" -w | xargs)
    IO:debug "$config_icon Expect : $option_count single parameter(s): $option_list"
    [[ $# -eq 0 ]] && IO:die "need the parameter(s) [$option_list]"

    for param in $single_params; do
      [[ $# -eq 0 ]] && IO:die "need parameter [$param]"
      [[ -z "$1" ]] && IO:die "need parameter [$param]"
      IO:debug "$config_icon Assign : $param=$1"
      eval "$param=\"$1\""
      shift
    done
  else
    IO:debug "$config_icon No single params to process"
    single_params=""
    option_count=0
  fi

  if Option:has_optional; then
    local optional_params
    local optional_count
    optional_params=$(Option:config | grep 'param|?|' | cut -d'|' -f3)
    optional_count=$(wc <<< "$optional_params" -w | xargs)
    IO:debug "$config_icon Expect : $optional_count optional parameter(s): $(echo "$optional_params" | xargs)"

    for param in $optional_params; do
      IO:debug "$config_icon Assign : $param=${1:-}"
      eval "$param=\"${1:-}\""
      shift
    done
  else
    IO:debug "$config_icon No optional params to process"
    optional_params=""
    optional_count=0
  fi

  if Option:has_multi; then
    #IO:debug "Process: multi param"
    local multi_count
    local multi_param
    multi_count=$(Option:config | grep -c 'param|n|')
    multi_param=$(Option:config | grep 'param|n|' | cut -d'|' -f3)
    IO:debug "$config_icon Expect : $multi_count multi parameter: $multi_param"
    ((multi_count > 1)) && IO:die "cannot have >1 'multi' parameter: [$multi_param]"
    ((multi_count > 0)) && [[ $# -eq 0 ]] && IO:die "need the (multi) parameter [$multi_param]"
    # save the rest of the params in the multi param
    if [[ -n "$*" ]]; then
      IO:debug "$config_icon Assign : $multi_param=$*"
      eval "$multi_param=( $* )"
    fi
  else
    multi_count=0
    multi_param=""
    [[ $# -gt 0 ]] && IO:die "cannot interpret extra parameters"
  fi
}

function Os:require() {
  local install_instructions
  local binary
  local words
  local path_binary
  # $1 = binary that is required
  binary="$1"
  path_binary=$(command -v "$binary" 2> /dev/null)
  [[ -n "$path_binary" ]] && IO:debug "️$require_icon required [$binary] -> $path_binary" && return 0
  # $2 = how to install it
  IO:alert "$script_basename needs [$binary] but it cannot be found"
  words=$(echo "${2:-}" | wc -w)
  install_instructions="$install_package $1"
  [[ $words -eq 1 ]] && install_instructions="$install_package $2"
  [[ $words -gt 1 ]] && install_instructions="${2:-}"
  if ((force)); then
    IO:announce "Installing [$1] ..."
    eval "$install_instructions"
  else
    IO:alert "1) install package  : $install_instructions"
    IO:alert "2) check path       : export PATH=\"[path of your binary]:\$PATH\""
    IO:die "Missing program/script [$binary]"
  fi
}

function Os:folder() {
  if [[ -n "$1" ]]; then
    local folder="$1"
    local max_days=${2:-365}
    if [[ ! -d "$folder" ]]; then
      IO:debug "$clean_icon Create folder : [$folder]"
      mkdir -p "$folder"
    else
      IO:debug "$clean_icon Cleanup folder: [$folder] - delete files older than $max_days day(s)"
      find "$folder" -mtime "+$max_days" -type f -exec rm {} \;
    fi
  fi
}

function Os:follow_link() {
  [[ ! -L "$1" ]] && echo "$1" && return 0 ## if it's not a symbolic link, return immediately
  local file_folder link_folder link_name symlink
  file_folder="$(dirname "$1")" ## check if file has absolute/relative/no path
  [[ "$file_folder" != /* ]] && file_folder="$(cd -P "$file_folder" &> /dev/null && pwd)" ## a relative path was given, resolve it
  symlink=$(readlink "$1") ## follow the link
  link_folder=$(dirname "$symlink") ## check if link has absolute/relative/no path
  [[ -z "$link_folder" ]] && link_folder="$file_folder" ## if no link path, stay in same folder
  [[ "$link_folder" == \.* ]] && link_folder="$(cd -P "$file_folder" && cd -P "$link_folder" &> /dev/null && pwd)" ## a relative link path was given, resolve it
  link_name=$(basename "$symlink")
  IO:debug "$info_icon Symbolic ln: $1 -> [$link_folder/$link_name]"
  Os:follow_link "$link_folder/$link_name" ## recurse
}

function Os:notify() {
  # cf https://levelup.gitconnected.com/5-modern-bash-scripting-techniques-that-only-a-few-programmers-know-4abb58ddadad
  local message="$1"
  local source="${2:-$script_basename}"

  [[ -n $(command -v notify-send) ]] && notify-send "$source" "$message"                                      # for Linux
  [[ -n $(command -v osascript) ]] && osascript -e "display notification \"$message\" with title \"$source\"" # for MacOS
}

function Os:busy() {
  # show spinner as long as process $pid is running
  local pid="$1"
  local message="${2:-}"
  local frames=("|" "/" "-" "\\")
  (
    while kill -0 "$pid" &> /dev/null; do
      for frame in "${frames[@]}"; do
        printf "\r[ $frame ] %s..." "$message"
        sleep 0.5
      done
    done
    printf "\n"
  )
}

function Os:beep() {
  local type="${1=-info}"
  case $type in
    *)
      tput bel
      ;;
  esac
}

function Script:meta() {
  git_repo_remote=""
  git_repo_root=""
  os_kernel=""
  os_machine=""
  os_name=""
  os_version=""
  script_hash="?"
  script_lines="?"
  shell_brand=""
  shell_version=""

  script_prefix=$(basename "${BASH_SOURCE[0]}" .sh)
  script_basename=$(basename "${BASH_SOURCE[0]}")
  execution_day=$(date "+%Y-%m-%d")

  script_install_path="${BASH_SOURCE[0]}"
  IO:debug "$info_icon Script path: $script_install_path"
  script_install_path=$(Os:follow_link "$script_install_path")
  IO:debug "$info_icon Linked path: $script_install_path"
  script_install_folder="$(cd -P "$(dirname "$script_install_path")" && pwd)"
  IO:debug "$info_icon In folder  : $script_install_folder"
  if [[ -f "$script_install_path" ]]; then
    script_hash=$(Str:digest < "$script_install_path" 8)
    script_lines=$(awk < "$script_install_path" 'END {print NR}')
  fi

  # get shell/operating system/versions
  shell_brand="sh"
  shell_version="?"
  [[ -n "${ZSH_VERSION:-}" ]] && shell_brand="zsh" && shell_version="$ZSH_VERSION"
  [[ -n "${BASH_VERSION:-}" ]] && shell_brand="bash" && shell_version="$BASH_VERSION"
  [[ -n "${FISH_VERSION:-}" ]] && shell_brand="fish" && shell_version="$FISH_VERSION"
  [[ -n "${KSH_VERSION:-}" ]] && shell_brand="ksh" && shell_version="$KSH_VERSION"
  IO:debug "$info_icon Shell type : $shell_brand - version $shell_version"
  if [[ "$shell_brand" == "bash" && "${BASH_VERSINFO:-0}" -lt 4 ]]; then
    IO:die "Bash version 4 or higher is required - current version = ${BASH_VERSINFO:-0}"
  fi

  os_kernel=$(uname -s)
  os_version=$(uname -r)
  os_machine=$(uname -m)
  install_package=""
  case "$os_kernel" in
    CYGWIN* | MSYS* | MINGW*)
      os_name="Windows"
      ;;
    Darwin)
      os_name=$(sw_vers -productName)       # macOS
      os_version=$(sw_vers -productVersion) # 11.1
      install_package="brew install"
      ;;
    Linux | GNU*)
      if [[ $(command -v lsb_release) ]]; then
        # 'normal' Linux distributions
        os_name=$(lsb_release -i | awk -F: '{$1=""; gsub(/^[\s\t]+/,"",$2); gsub(/[\s\t]+$/,"",$2); print $2}')    # Ubuntu/Raspbian
        os_version=$(lsb_release -r | awk -F: '{$1=""; gsub(/^[\s\t]+/,"",$2); gsub(/[\s\t]+$/,"",$2); print $2}') # 20.04
      else
        # Synology, QNAP,
        os_name="Linux"
      fi
      [[ -x /bin/apt-cyg ]] && install_package="apt-cyg install"     # Cygwin
      [[ -x /bin/dpkg ]] && install_package="dpkg -i"                # Synology
      [[ -x /opt/bin/ipkg ]] && install_package="ipkg install"       # Synology
      [[ -x /usr/sbin/pkg ]] && install_package="pkg install"        # BSD
      [[ -x /usr/bin/pacman ]] && install_package="pacman -S"        # Arch Linux
      [[ -x /usr/bin/zypper ]] && install_package="zypper install"   # Suse Linux
      [[ -x /usr/bin/emerge ]] && install_package="emerge"           # Gentoo
      [[ -x /usr/bin/yum ]] && install_package="yum install"         # RedHat RHEL/CentOS/Fedora
      [[ -x /usr/bin/apk ]] && install_package="apk add"             # Alpine
      [[ -x /usr/bin/apt-get ]] && install_package="apt-get install" # Debian
      [[ -x /usr/bin/apt ]] && install_package="apt install"         # Ubuntu
      ;;

  esac
  IO:debug "$info_icon System OS  : $os_name ($os_kernel) $os_version on $os_machine"
  IO:debug "$info_icon Package mgt: $install_package"

  # get last modified date of this script
  script_modified="??"
  [[ "$os_kernel" == "Linux" ]] && script_modified=$(stat -c %y "$script_install_path" 2> /dev/null | cut -c1-16) # generic linux
  [[ "$os_kernel" == "Darwin" ]] && script_modified=$(stat -f "%Sm" "$script_install_path" 2> /dev/null)          # for MacOS

  IO:debug "$info_icon Version  : $script_version"
  IO:debug "$info_icon Created  : $script_created"
  IO:debug "$info_icon Modified : $script_modified"

  IO:debug "$info_icon Lines    : $script_lines lines / md5: $script_hash"
  IO:debug "$info_icon User     : $USER@$HOSTNAME"

  # if run inside a git repo, detect for which remote repo it is
  if git status &> /dev/null; then
    git_repo_remote=$(git remote -v | awk '/(fetch)/ {print $2}')
    IO:debug "$info_icon git remote : $git_repo_remote"
    git_repo_root=$(git rev-parse --show-toplevel)
    IO:debug "$info_icon git folder : $git_repo_root"
  fi

  # get script version from VERSION.md file - which is automatically updated by pforret/setver
  [[ -f "$script_install_folder/VERSION.md" ]] && script_version=$(cat "$script_install_folder/VERSION.md")
  # get script version from git tag file - which is automatically updated by pforret/setver
  [[ -n "$git_repo_root" ]] && [[ -n "$(git tag &> /dev/null)" ]] && script_version=$(git tag --sort=version:refname | tail -1)
}

function Script:initialize() {
  log_file=""
  if [[ -n "${tmp_dir:-}" ]]; then
    # clean up TMP folder after 1 day
    Os:folder "$tmp_dir" 1
  fi
  if [[ -n "${log_dir:-}" ]]; then
    # clean up LOG folder after 1 month
    Os:folder "$log_dir" 30
    log_file="$log_dir/$script_prefix.$execution_day.log"
    IO:debug "$config_icon log_file: $log_file"
  fi
}

function Os:tempfile() {
  local extension=${1:-txt}
  local file="${tmp_dir:-/tmp}/$execution_day.$RANDOM.$extension"
  IO:debug "$config_icon tmp_file: $file"
  temp_files+=("$file")
  echo "$file"
}

function Os:import_env() {
  local env_files
  if [[ $(pwd) == "$script_install_folder" ]]; then
    env_files=(
      "$script_install_folder/.env"
      "$script_install_folder/.$script_prefix.env"
      "$script_install_folder/$script_prefix.env"
    )
  else
    env_files=(
      "$script_install_folder/.env"
      "$script_install_folder/.$script_prefix.env"
      "$script_install_folder/$script_prefix.env"
      "./.env"
      "./.$script_prefix.env"
      "./$script_prefix.env"
    )
  fi

  for env_file in "${env_files[@]}"; do
    if [[ -f "$env_file" ]]; then
      IO:debug "$config_icon Read  dotenv: [$env_file]"
      local clean_file
      clean_file=$(Os:clean_env "$env_file")
      # shellcheck disable=SC1090
      source "$clean_file" && rm "$clean_file"
    fi
  done
}

function Os:clean_env() {
  local input="$1"
  local output="$1.__.sh"
  [[ ! -f "$input" ]] && IO:die "Input file [$input] does not exist"
  IO:debug "$clean_icon Clean dotenv: [$output]"
  awk < "$input" '
      function ltrim(s) { sub(/^[ \t\r\n]+/, "", s); return s }
      function rtrim(s) { sub(/[ \t\r\n]+$/, "", s); return s }
      function trim(s) { return rtrim(ltrim(s)); }
      /=/ { # skip lines with no equation
        $0=trim($0);
        if(substr($0,1,1) != "#"){ # skip comments
          equal=index($0, "=");
          key=trim(substr($0,1,equal-1));
          val=trim(substr($0,equal+1));
          if(match(val,/^".*"$/) || match(val,/^\047.*\047$/)){
            print key "=" val
          } else {
            print key "=\"" val "\""
          }
        }
      }
  ' > "$output"
  echo "$output"
}

IO:initialize # output settings
Script:meta   # find installation folder

[[ $run_as_root == 1 ]] && [[ $UID -ne 0 ]] && IO:die "user is $USER, MUST be root to run [$script_basename]"
[[ $run_as_root == -1 ]] && [[ $UID -eq 0 ]] && IO:die "user is $USER, CANNOT be root to run [$script_basename]"

Option:initialize # set default values for flags & options
Os:import_env     # overwrite with .env if any

if [[ $sourced -eq 0 ]]; then
  Option:parse "$@" # overwrite with specified options if any
  Script:initialize # clean up folders
  Script:main       # run Script:main program
  Script:exit       # exit and clean up
else
  # just disable the trap, don't execute Script:main
  trap - INT TERM EXIT
fi