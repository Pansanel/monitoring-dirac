#!/bin/bash

# Copyright (C) 2016 CNRS - IdGC - France-Grilles
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Description:
#   Main DIRAC probe :
#      Can submit jobs or check jobs workflow
#      Management of dirac's command's timeouts
#      Max script execution time of ~300s (nagios)
#
# Changelog:
# v0.1 2016-12-01 Vincent Gatignol-Jamon <gatignol-jamon@idgrilles.fr>
#      Initial Release
# v0.2 2016-12-07 Vincent Gatignol-Jamon <gatignol-jamon@idgrilles.fr>
#      Add timeout management of dirac's commands
#      Workflow review
# v0.3 2016-12-09 Vincent Gatignol-Jamon <gatignol-jamon@idgrilles.fr>
#      Better timeout management (dirac + overall script)
# v0.4 2016-12-13 Vincent Gatignol-Jamon <gatignol-jamon@idgrilles.fr>
#      Not using subprocess (better calculation of nb_jobs/nb_cmds)

## Please adapt to your local settings

# path to dirac client
DIRAC_PATH=/usr/lib/dirac

# temporary path (subdirs "dirac-jobs", "dirac-outputs" and "dirac-logs" will
# be created here).
TMP_PATH=/tmp

# activate debug logs ?
DEBUG=true

# where to put the logs
DEBUGFILE=$TMP_PATH/dirac_debug_log

# time allowed for dirac's commands to execute (seconds)
TIMEOUT="30"

# Nagios timeout (seconds)
NAGIOS_TIMEOUT="300"

# Job name / comparison sting (no space)
TXT="FG_Monitoring_Simple_Job"

# These global vars are not defined for this nagios user/session
# (only defined by dirac-proxy-init)
export X509_CERT_DIR=/etc/grid-security/certificates
export X509_USER_CERT=~/.globus/usercert.pem
export X509_USER_KEY=~/.globus/userkey.pem
export X509_USER_PROXY=/tmp/x509up_u500

## Do not edit below this line ##

PROBE_VERSION="0.4"

## Workflow
# ---------
# * source DIRAC environment (bashrc)
# * each dirac's command is checked against a timeout and its exit_code
#      - if timeout; return STATE_WARNING
# * check_env :
#      check_dirac_environment
#      check_proxy
#         if proxy_is_valid < 7 days
#            return STATE_WARNING
#         if proxy_is_valid < 1 day
#            return STATE_CRITICAL
#      check_or_create $TMP_PATH/{dirac-jobs,dirac-outputs}
#      create_jdl
#
# * Create jobs (every 60 min)
#
#   submit_job:
#      store job_id as a timestamped file in $TMP_PATH/dirac-jobs
#   submit_job:
#      store job_id as a timestamped file in $TMP_PATH/dirac-jobs
#      wait 2s
#      delete the job (job will have status=Killed)
#
# * Check jobs (every 60 min)
#
#   For each job_id in $TMP_PATH/dirac-jobs : check_job_status
#
#   if Status in { Received, Checking, Waiting, Running,
#              Matched, Completed, Deleted }
#      do_nothing/wait
#      if job_created < 4h
#         return STATE_OK
#      else
#         return STATE_WARNING
#
#   if Status = Done
#      check_job_output
#      if output is expected
#         return STATE_OK
#      else
#         return STATE_CRITICAL
#      delete_job
#
#   if Status = Stalled
#      if job_created < 4h
#         do_nothing/wait
#         return STATE_OK
#      else
#         delete_job
#         return STATE_WARNING
#
#   if Status = Failed
#      delete_job
#      return STATE_CRITICAL
#
#   if Status = Killed
#      if job_created < 1h
#         do_nothing/wait
#      else
#         reschedule_job
#      return STATE_OK
#
#   if Status = JobNotFound
#      clean_job in $TMP_PATH
#      return STATE_OK

## List of job statuses
# ---------------------
# Received     Job is received by the DIRAC WMS
# Checking     Job is being checked for sanity by the DIRAC WMS
# Waiting      Job is entered into the Task Queue and is waiting to picked up
#            for execution
# Running      Job is running
# Stalled      Job has not shown any sign of life since 2 hours while in the
#            Running state
# Completed    Job finished execution of the user application, but some pending
#            operations remain
# Done        Job is fully finished
# Failed      Job is finished unsuccessfully
# Killed      Job received KILL signal from the user
# Deleted      Job is marked for deletion
# Matched      ?

# Nagios exit status codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4
STATUS_ALL=('OK' 'WARNING' 'CRITICAL' 'UNKNOWN' 'DEPENDENT')

# Others
STATE_TIMEOUT=5
STATE_CMD_OK=6
EXIT_CODE=$STATE_OK
NOTIMEOUT="false"

# Output computing stuff
NB_JOBS=0
NB_JOBS_OK=0
NB_JOBS_WARNING=0
NB_JOBS_CRITICAL=0
NB_CMDS=0
NB_TIMEOUTS=0
TIME_START=$(date +%s)
TXT_START=$(date +%Y%m%d_%H%M%S)

# Get DIRAC environment
source $DIRAC_PATH/bashrc

# unset LD_LIBRARY_PATH as it cause awk/sed to fail
unset LD_LIBRARY_PATH

## Functions

log() {
   local SEVERITY="$1"
   local TEXT="$2"

   LOG_NOW=$(date '+%Y-%m-%d %H:%M:%S %Z')

   if [ "$SEVERITY" = "D" ]; then
      echo -e "$LOG_NOW [$SEVERITY] $TEXT" >> $DEBUGFILE
   else
      echo "$LOG_NOW [$SEVERITY] $TEXT" >> $JOB_LOGS/$TXT_START.log
   fi

   if [ $DEBUG ] && [ "$SEVERITY" != "D" ]; then
      echo -e "$LOG_NOW [$SEVERITY] $TEXT" >> $DEBUGFILE
   fi
}

perf_compute() {
   PERF_STATUS=$1

   # Job count
   if [ "$PERF_STATUS" = "$STATE_OK" ]; then
      ((NB_JOBS++))
      ((NB_JOBS_OK++))
   elif [ "$PERF_STATUS" = "$STATE_WARNING" ]; then
      ((NB_JOBS++))
      ((NB_JOBS_WARNING++))
   elif [ "$PERF_STATUS" = "$STATE_CRITICAL" ]; then
      ((NB_JOBS++))
      ((NB_JOBS_CRITICAL++))
   fi

   # Command count
   if [ "$PERF_STATUS" = "$STATE_TIMEOUT" ]; then
      ((NB_CMDS++))
      ((NB_TIMEOUTS++))
      PERF_STATUS=$STATE_WARNING
   elif [ "$PERF_STATUS" = "$STATE_CMD_OK" ]; then
      ((NB_CMDS++))
      PERF_STATUS=$STATE_OK
   fi

   if [ "$PERF_STATUS" -gt "$EXIT_CODE" ]; then
      EXIT_CODE=$PERF_STATUS
   fi
}

perf_exit() {
   EXIT_STATUS=${STATUS_ALL[$1]}
   PERF_NOW=$(date +%s)
   EXEC_TIME=$(( $PERF_NOW - $TIME_START ))
   OUT_PERF="exec_time=$EXEC_TIME;;;; nb_jobs=$NB_JOBS;;;; nb_jobs_ok=$NB_JOBS_OK;;;; nb_jobs_ko=$NB_JOBS_CRITICAL;;;; nb_jobs_warn=$NB_JOBS_WARNING;;;; nb_cmds=$NB_CMDS;;;; nb_timeouts=$NB_TIMEOUTS;;;;"
   OUT_TXT="exec_time=$EXEC_TIME; nb_jobs=$NB_JOBS; nb_jobs_ok=$NB_JOBS_OK; nb_jobs_ko=$NB_JOBS_CRITICAL; nb_jobs_warn=$NB_JOBS_WARNING; nb_cmds=$NB_CMDS; nb_timeouts=$NB_TIMEOUTS;"
   echo "$EXIT_STATUS / $OUT_TXT"
   log "I" "$OUT_TXT"
   log "I" "Global status : $EXIT_STATUS"
   cat $JOB_LOGS/$TXT_START.log
   echo "|$OUT_PERF"
   exit $1
}

usage () {
   log "I" "Displaying usage"
   echo "Usage: $0 [OPTION] ..."
   echo "Check some workflows on DIRAC"
   echo "Create a job and check its status"
   echo "Create a job, delete it, and check its status"
   echo ""
   echo "  -h|--help       Print this help message"
   echo "  -v|--version    Print probe version"
   echo "  -s|--submit     Submit test jobs"
   echo "  -c|--check      Check jobs statuses"
   echo "  -t|--notimeout  Do not stop process after 240s"
   echo ""
}

version() {
   log "D" "Displaying version ($PROBE_VERSION)"
   log "I" "$0 version $PROBE_VERSION"
}

check_exit_code() {
   LAST_EXIT_CODE=$1
   TIMEOUT_STATUS="false"

   if [ "$LAST_EXIT_CODE" -eq "124" ]; then
      log "W" "There was a timeout ($TIMEOUT s) in dirac command"
      log "D" "Exit code is $LAST_EXIT_CODE : timeout"
      perf_compute $STATE_TIMEOUT
      TIMEOUT_STATUS="true"
      if [ "$EXIT_CODE" -lt "$STATE_WARNING" ]; then
         EXIT_CODE=$STATE_WARNING
      fi
   elif [ "$LAST_EXIT_CODE" -eq "0" ]; then
      log "I" "Exit code is $LAST_EXIT_CODE : ok"
      perf_compute $STATE_CMD_OK
   else
      log "I" "TODO EXIT_CODE = $LAST_EXIT_CODE"
      perf_compute $STATE_CMD_OK
      fi

   # TODO Check unknown exit codes
}

check_timeout() {
   OUTPUT=""

   log "I" "Running command : $1"
   OUTPUT=$(timeout $TIMEOUT $1)
   check_exit_code $?
}

check_paths() {
   JOB_LIST=$TMP_PATH/dirac-jobs
   JOB_OUT=$TMP_PATH/dirac-outputs
   JOB_LOGS=$TMP_PATH/dirac-logs

   for DPATH in dirac-jobs dirac-outputs dirac-logs; do
      if [ ! -d $TMP_PATH/$DPATH ]; then
         mkdir -p $TMP_PATH/$DPATH
         log "W" "$TMP_PATH/$DPATH Not found !"
         log "I" "Creating in $TMP_PATH/$DPATH"
      fi
   done
}

check_env() {
   local TIME_LEFT="0"

   log "I" "Checking environment and proxy..."

   if [ -z "$DIRAC" ]; then
      log "C" "DIRAC environment not set !"
      log "C" "Please check probe configuration (DIRAC_PATH ?)"
      perf_exit $STATE_CRITICAL
   fi

   check_timeout "$DIRACSCRIPTS/dirac-proxy-info -v"
   TIME_LEFT=$(echo "$OUTPUT" | awk '/timeleft/ { print $3 }')
   TIME_LEFT=$(echo "$TIME_LEFT" | awk -F ":" '{ print $1 }')

   if [ "$TIMEOUT_STATUS" = "true" ] || [ "$TIME_LEFT" -ne "$TIME_LEFT" ] 2>/dev/null; then
      if [ -f $X509_USER_PROXY ]; then
         log "W" "Try to use the current proxy ($X509_USER_PROXY)"
         EXIT_CODE=$STATE_WARNING
      else
         log "C" "Proxy not found !"
         log "C" "Did you initialise it with 'dirac-proxy-init -g biomed_user' ?"
         perf_exit $STATE_CRITICAL
      fi
   else
      if [ "$TIME_LEFT" -lt "24" ]; then
         log "C" "Proxy is valid for less than a day !!!"
         log "C" "Tip : 'dirac-proxy-init -g biomed_user -v 720:00'"
         EXIT_CODE=$STATE_CRITICAL
      elif [ "$TIME_LEFT" -lt "168" ]; then
         log "W" "Proxy is valid for less than a week !!!"
         log "W" "Tip : 'dirac-proxy-init -g biomed_user -v 720:00'"
         EXIT_CODE=$STATE_WARNING
      else
         log "I" "Proxy is valid for $TIME_LEFT h ($(($TIME_LEFT / 24)) d)"
         EXIT_CODE=$STATE_OK
      fi
   fi

   JDL=$TMP_PATH/$TXT.jdl

   log "I" "Creating JDL at $JDL"
   cat <<EOF > $JDL
JobName      = "$TXT";
Executable   = "/bin/echo";
Arguments    = "$TXT";
StdOutput    = "StdOut";
StdError     = "StdErr";
OutputSandbox = {"StdOut","StdErr"};
EOF
}

submit_job() {
   local OUT=$JOB_LIST/`date +%s`
   JOB_ID=""

   log "I" "Submitting job in $OUT"

   check_timeout "$DIRACSCRIPTS/dirac-wms-job-submit -f $OUT $JDL"

   JOB_ID=$(cat $OUT)
   if [ "$TIMEOUT_STATUS" = "true" ] || [ "$JOB_ID" -ne "$JOB_ID" ] 2>/dev/null; then
      log "C" "Cannot submit job !"
      JOB_ID="None"
      perf_compute $STATE_CRITICAL
      if [ -f $OUT ]; then
         rm $OUT
      fi
   else
      log "I" "JobId submitted is $JOB_ID"
      perf_compute $STATE_OK
   fi
}

delete_job() {
   log "I" "Deleting job $1"
   check_timeout "$DIRACSCRIPTS/dirac-wms-job-delete $1"
}

kill_job() {
   log "I" "Killing job $1"
   check_timeout "$DIRACSCRIPTS/dirac-wms-job-kill $1"
}

reschedule_job() {
   log "I" "Rescheduling job $1"
   check_timeout "$DIRACSCRIPTS/dirac-wms-job-reschedule $1"
}

clean_job() {
   local ID="$1"
   local FILE="$2"

   log "I" "Cleaning job $ID ($FILE)"

   if [ -d $JOB_OUT/$ID ]; then
      log "I" "Removing $JOB_OUT/$ID/* : $(rm $JOB_OUT/$ID/*)"
      log "I" "Removing $JOB_OUT/$ID/  : $(rmdir $JOB_OUT/$ID)"
   else
      log "I" "Directory $JOB_OUT/$ID not found (so not deleted)..."
   fi
   # TODO
   # Really check if file exist : if [ -z ${FILE+x} ] && [ -f $FILE ]; then
   if [ -f $FILE ]; then
      log "I" "Removing $FILE $(rm $FILE)"
   else
      log "I" "File $FILE Not found (so not removed)..."
   fi
}

check_time() {
   local ID=$1
   local FILE=$2
   local TIME_WINDOW=$(( $3 - 1 ))
   local SUB_TIME=$(basename $FILE)
   local NOW=$(date +%s)
   local DELTA=$(( $NOW - $SUB_TIME - 1 ))

   log "I" "Checking if job was created less than $(date +%-H --date=@$TIME_WINDOW)h ago"
   log "I" "Time difference is $DELTA s"

   if [ $DELTA -lt "$TIME_WINDOW" ]; then
      log "I" "Seems good, waiting..."
      RCODE=$STATE_OK
      ACTION="Waiting"
   else
      log "W" "Seems too long !"
      RCODE=$STATE_WARNING
      ACTION="Taking too long time !"
   fi
}

check_status() {
   ID=$1
   FILE=$2

   RCODE=$STATE_UNKNOWN
   ACTION="Not_defined_yet"

   log "I" "Checking status of job $ID"
   check_timeout "$DIRACSCRIPTS/dirac-wms-job-status $ID"

   STATUS=$(echo "$OUTPUT" | awk '/Status=/ {print $2}')

   if [ "$STATUS" = "" ]; then
      if [ "$TIMEOUT_STATUS" = "true" ]; then
         RCODE=$STATE_WARNING
         ACTION="None/Timeout"
         STATUS="Status=UnKnown;"
         log "I" "$STATUS"
      else
         RCODE=$STATE_OK
         ACTION="Cleaning"
         STATUS="Status=NotFound;"
         log "I" "$STATUS"
         clean_job "$ID" "$FILE"
      fi
   else
      log "I" "$STATUS"
   fi

   if [ "$STATUS" = "Status=Received;" ]; then
      check_time $ID $FILE 14400

   elif [ "$STATUS" = "Status=Checking;" ]; then
      check_time $ID $FILE 14400

   elif [ "$STATUS" = "Status=Waiting;" ]; then
      check_time $ID $FILE 14400

   elif [ "$STATUS" = "Status=Running;" ]; then
      check_time $ID $FILE 14400

   elif [ "$STATUS" = "Status=Matched;" ]; then
      check_time $ID $FILE 14400

   elif [ "$STATUS" = "Status=Completed;" ]; then
      check_time $ID $FILE 14400

   elif [ "$STATUS" = "Status=Deleted;" ]; then
      check_time $ID $FILE 14400

   elif [ "$STATUS" = "Status=Done;" ]; then
      log "I" "Checking output of job $ID"
      check_timeout "$DIRACSCRIPTS/dirac-wms-job-get-output -D $JOB_OUT $ID"
      if [ -f $JOB_OUT/$ID/StdOut ] && [ "$(cat $JOB_OUT/$ID/StdOut)" = "$TXT" ]; then
         log "I" "Output is good !"
         delete_job $ID
         if [ "$TIMEOUT_STATUS" = "true" ]; then
            ACTION="None/Timeout"
            RCODE=$STATE_WARNING
         elif [ "$LAST_EXIT_CODE" -ne "$STATE_OK" ]; then
            ACTION="None/Error"
            RCODE=$STATE_WARNING
         else
            ACTION="Deleting"
            RCODE=$STATE_OK
         fi
      elif [ "$TIMEOUT_STATUS" = "true" ]; then
         log "W" "Cannot stat Output (timeout)"
         RCODE=$STATE_WARNING
         ACTION="None/Timeout"
      else
         log "C" "Output is bad.."
         RCODE=$STATE_CRITICAL
         ACTION="None/Error"
      fi

   elif [ "$STATUS" = "Status=Stalled;" ]; then
      check_time $ID $FILE 14400
      if [ "$RCODE" -gt "$STATE_OK" ]; then
         delete_job $ID
         if [ "$TIMEOUT_STATUS" = "true" ]; then
            ACTION="None/Timeout"
         elif [ "$LAST_EXIT_CODE" -ne "$STATE_OK" ]; then
            ACTION="None/Error"
         else
            ACTION="Deleting"
         fi
      fi

   elif [ "$STATUS" = "Status=Failed;" ]; then
      delete_job $ID
      if [ "$TIMEOUT_STATUS" = "true" ]; then
         ACTION="None/Timeout"
      elif [ "$LAST_EXIT_CODE" -ne "$STATE_OK" ]; then
         ACTION="None/Error"
      else
         ACTION="Deleting"
      fi
      RCODE="$STATE_CRITICAL"

   elif [ "$STATUS" = "Status=Killed;" ]; then
      check_time $ID $FILE 3600
      if [ "$RCODE" -gt "$STATE_OK" ]; then
         reschedule_job $ID
         if [ "$TIMEOUT_STATUS" = "true" ]; then
            ACTION="None/Timeout"
         elif [ "$LAST_EXIT_CODE" -ne "$STATE_OK" ]; then
            ACTION="None/Error"
         else
            ACTION="Rescheduling"
            RCODE=$STATE_OK
         fi
      fi
   fi

   log "I" "JobID $ID : $STATUS Action=$ACTION; (${STATUS_ALL[$RCODE]})"
}

## Go for it !

start_jobs() {
   log "I" "------------- New submission starting --------------"
   check_env
   log "I" "Submitting some jobs..."

   log "I" "---"
   submit_job

   log "I" "---"
   submit_job

   if [ "$TIMEOUT_STATUS" = "true" ] || [ "$JOB_ID" -ne "$JOB_ID" ] 2>/dev/null; then
      log "W" "Last Submission failed, cannot kill nonexistent job"
   else
      log "I" "JobID to be killed : $JOB_ID"
      kill_job $JOB_ID

      if [ "$TIMEOUT_STATUS" = "true" ]; then
         ACTION="None/Timeout"
         perf_compute $STATE_WARNING
      elif [ "$LAST_EXIT_CODE" -ne "$STATE_OK" ]; then
         ACTION="None/Error"
         perf_compute $STATE_WARNING
      else
         ACTION="Killing"
         perf_compute $STATE_OK
      fi
   fi
}

check_jobs() {
   log "I" "--------------- New check starting -----------------"
   check_env
   log "I" "Checking jobs from files (if any)..."

   local FILES="$(find $JOB_LIST -type f | sort)"
   if [ "$(echo -ne ${FILES} | wc -m)" -gt "0" ]; then

      ALLOWED_TIME=$(date +%-Mm%-Ss --date=@$((NAGIOS_TIMEOUT - (TIMEOUT * 3) - 2 )))
      T_START=$(date +%-H:%-M:%-S --date=@$TIME_START)
      log "I" "Total allowed running time before skipping jobs : $ALLOWED_TIME (from $T_START)"

      for FILE in $FILES; do
         JOB_ID=$(cat $FILE)
         log "I" "---"
         if [ "$JOB_ID" -eq "$JOB_ID" ] 2>/dev/null; then
            TIME_NOW=$(date +%s)
            log "I" "We have an integer, assuming this is a JobID"
            if [ "$(( $TIME_NOW - $TIME_START ))" -lt "230" ] || [ "$NOTIMEOUT" = "true" ] ; then
               log "I" "Found JobID $JOB_ID from file $FILE"
               check_status $JOB_ID $FILE
               perf_compute $RCODE
            else
               log "W" "The script was lauched almost $ALLOWED_TIME ago..."
               log "W" "Skipping job $JOB_ID"
               perf_compute $STATE_WARNING
               log "W" "JobID $JOB_ID : NotChecked / Action=Skipping; (WARNING)"
            fi
         else
            log "W" "What is this ? ($JOB_ID from $FILE) Is not a JobID !"
         fi
      done
   else
      log "I" "No job found to ckeck."
   fi
}

## Parse arguments

# No argument given
if [ $# -eq 0 ] ; then
   usage
fi

# Validate options
if ! OPTIONS=$(getopt -o chstv -l check,help,submit,notimeout,version -- "$@") ; then
   usage
fi

while [ $# -gt 0 ]; do
   case "$1" in
      -t|--notimeout)
         NOTIMEOUT="true"
         log "I" "Run without a 300s timeout !"
         shift
         ;;
      -h|--help)
         RUN="usage"
         shift
         ;;
      -v|--version)
         RUN="version"
         shift
         ;;
      -s|--submit)
         RUN="start_jobs"
         shift
         ;;
      -c|--check)
         RUN="check_jobs"
         shift
         ;;
      *)
         echo "Incorrect input : $1"
         RUN="incorrect"
         shift
         ;;
   esac
done

if [ "$RUN" = "usage" ]; then
   check_paths
   usage
   perf_exit $STATE_OK
elif [ "$RUN" = "version" ]; then
   check_paths
   version
   perf_exit $STATE_OK
elif [ "$RUN" = "start_jobs" ]; then
   check_paths
   start_jobs
   perf_exit $EXIT_CODE
elif [ "$RUN" = "check_jobs" ]; then
   check_paths
   check_jobs
   perf_exit $EXIT_CODE
else
   check_paths
   usage
   perf_exit $STATE_CRITICAL
fi

#EOF
