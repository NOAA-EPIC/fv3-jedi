#!/bin/bash

# (C) Copyright 2020-2022 UCAR
#
# This software is licensed under the terms of the Apache Licence Version 2.0
# which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.

set -eux

cd $WORKDIR

echo $COSTFUNCTION
echo $RESTARTDIR
echo $INPUTDIR
echo $PREFIX

# Move files from RESTART to INPUT + rename if 3dfgat cost function
if [ -d  $RESTARTDIR ] && [ $COSTFUNCTION == "3D-FGAT" ]
then
  echo "3D-FGAT cost function, moving 3hrs forecast files to $INPUTDIR"
  list_files=("fv_core.res" "fv_srf_wnd.res" "fv_tracer.res" "phy_data" "sfc_data")
  for file in ${list_files[@]}; do
    for tile in {1..6}; do
      filerestart="$RESTARTDIR/${PREFIX}.${file}.tile${tile}.nc"
      fileinput="$INPUTDIR/${file}.tile${tile}.nc"
      cp $filerestart $fileinput
    done
  done
  couplerrestart="$RESTARTDIR/${PREFIX}.coupler.res"
  couplerinput="$INPUTDIR/coupler.res"
  cp $couplerrestart $couplerinput
fi
rm $RESTARTDIR/*

set +e
$MPICMD $JEDIEXEC --no-validate $1 2> stderr.$$.log 1> stdout.$$.log
exit_code=$?
set -e

pwd
ls -ltr

cat stdout.$$.log
[[ -s stderr.$$.log ]] && cat stderr.$$.log

if [ $exit_code -ne 0 ]
then
  echo "Task failed with error code $exit_code"
  exit $exit_code
fi

# Copy log file to output used for diagnostics
cp stdout.$$.log $LOGFILE
