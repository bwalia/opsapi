#!/bin/bash
#
# Author: Patrick Bailey
# License: MIT
#
# Set the percentage of 200, 404, and 500 errors you want
# Set the hourly rate you want
# Set a URL for 200, 404 and 500
#
# Then run it.  it will suffle the 200, 404, and 500 urls
# (Just for testing)
#
#####################################

#Number of codes to send per type
#It will keep looping
PERC_200=60
PERC_404=30
PERC_500=40

PER_HOUR=75000

URL="http://localhost"
URL_404="http://localhost/404.html"
URL_500="http://localhost/500"

TOTAL_200=0
TOTAL_404=0
TOTAL_500=0

START=$(date +%s%N)

# trap ctrl-c and call ctrl_c()
trap ctrl_c INT

function ctrl_c() {
   echo ""
   echo "Statistics "
   echo "200 Total: $TOTAL_200"
   echo "404 Total: $TOTAL_404"
   echo "500 Total: $TOTAL_500"
   exit 0
}

ARRAY=()
function create_array() {
  ARRAY=()
  for i in $( eval echo {1..$PERC_200} )
  do
    ARRAY+=($URL)
  done
  for i in $( eval echo {1..$PERC_404} )
  do
    ARRAY+=($URL_404)
  done
  for i in $( eval echo {1..$PERC_500} )
  do
    ARRAY+=($URL_500)
  done

  ARRAY=($(shuf -e "${ARRAY[@]}"))
}

create_array
NUM=0
TIME_CHECK=0
OLD_PAUSE_TIMER=0
TIME=$START
NUM_MSGS=10
#Number of nanoseconds it should take between runs
NUM_NSEC=$((3600 * $NUM_MSGS * 1000000000/$PER_HOUR))
#NUM_SEC=$(($NUM_NSEC/1000000000))
#NUM_MSEC=$(($NUM_SEC))$((($NUM_NSEC - $NUM_SEC*1000000000)/1000000 ))


while :
do
  LOCAL_URL=${ARRAY[$NUM]}
  curl -s -o /dev/null -w '%{http_code}' $LOCAL_URL
  echo""

  if [ "$LOCAL_URL" == "$URL" ]
    then
    ((TOTAL_200+=1))
  fi
  if [ "$LOCAL_URL" == "$URL_404" ]
    then
    ((TOTAL_404+=1))
  fi
  if [ "$LOCAL_URL" == "$URL_500" ]
    then
    ((TOTAL_500+=1))
  fi


  ((NUM+=1))
  #Get a new random array
  if [ $NUM == ${#ARRAY[@]} ]
    then
    create_array
    NUM=0
  fi

  ((TIME_CHECK+=1))
  if [ $TIME_CHECK == 1000 ]
    then
    TIME_CHECK=0
  fi

  if ! (($TIME_CHECK % $NUM_MSGS)); then
    TIME_PRIOR=$TIME
    TIME=$(date +%s%N)

    #Get total rate
    TOTAL=$(($TOTAL_200 + $TOTAL_404 + $TOTAL_500))
    TOTAL_TIME_NS=$(($TIME - $START))
    TOTAL_RATE=$((3600*1000000000*$TOTAL/$TOTAL_TIME_NS))
    echo "TOTAL RATE: $TOTAL_RATE"
    CURRENT_RATE=$((3600*1000000000*$NUM_MSGS/($TIME - $TIME_PRIOR)))
    echo "CURRENT RATE: $CURRENT_RATE"

    #Calculate pause time
    PAUSE_NSEC=$(($NUM_NSEC - ($TIME - $TIME_PRIOR)))
    PAUSE_NSEC=$(($OLD_PAUSE_TIMER + $PAUSE_NSEC))
    if (( $PAUSE_NSEC > 0 ))
    then
      PAUSE_SEC=$(($PAUSE_NSEC/1000000000))
      PAUSE_TIMER=$(($PAUSE_SEC)).$((($PAUSE_NSEC - $PAUSE_SEC*1000000000)/1000000 ))
      OLD_PAUSE_TIMER=$PAUSE_NSEC
      sleep $PAUSE_TIMER
    fi
  fi
done