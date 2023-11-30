#!/bin/bash

set -x

mkdir input-data
export INPUTDATA_ROOT=$PWD/input-data
export INPUTDATA_ROOT_WW3=$PWD/input-data
export INPUTDATA_ROOT_BMIC=$PWD/input-data

export builddir=$1
export ufsdir=$2
export fv3jedidata=$3

baseline=`grep baseline $ufsdir/tests/logs/RegressionTests_hera.log | grep "\/control_c48_intel" | awk -F "/" '{print $7}'`

cd input-data
aws s3 sync --no-sign-request s3://noaa-ufs-regtests-pds/input-data-20221101/FV3_fix FV3_fix
aws s3 sync --no-sign-request s3://noaa-ufs-regtests-pds/input-data-20221101/FV3_input_data48 FV3_input_data48
aws s3 sync --no-sign-request s3://noaa-ufs-regtests-pds/$baseline/control_c48_intel/RESTART RESTART

export RT_SUFFIX=
export BL_SUFFIX=
export SCHEDULER=slurm
export ACCNR=da-cpu
export QUEUE=batch
export PARTITION=
export ROCOTO=false
export ECFLOW=false
export REGRESSIONTEST_LOG=$ufsdir/rlog
export LOG_DIR=$ufsdir/log
export DEP_RUN=
export skip_check_results=false
export delete_rundir=false
export WLCLK=30
export JOB_NR="001"
touch fv3_001.exe
touch modules.fv3_001.lua
export PATHTR=$ufsdir
export RT_COMPILER=intel
export MACHINE_ID=hera
mkdir -p $LOG_DIR
touch $LOGDIR/job_001_timestamp.txt
cd $ufsdir/tests
touch fv3_001.exe
touch modules.fv3_001.lua
source vars
./run_test.sh $PWD $fv3jedidata control_c48 001 001

cd $fv3jedidata/control_c48_intel
#sed -i 's/24/2/g' model_configure
#sed -i 's/6 -1/2 -1/g' model_configure
sed -i 's/quilting:                .true./quilting:                .false./g' model_configure 
sed -i 's/start_day:               22/start_day:               23/g' model_configure 
sed -i '/quilting_restart/d' model_configure 
cp $INPUTDATA_ROOT/RESTART/* INPUT
cd INPUT
for file in 20210323.060000.*; do new=$(echo $file | cut -c 17-) && mv -v -- "$file" "$new" ; done
sed -i 's/3    22/3    23/g' coupler.res 
cd ..
sed -i 's/0 7/0 5/g' ufs.configure
sed -i 's/warm_start = .false./warm_start = .true./g' input.nml
sed -i 's/make_nh = .true./make_nh = .false./g' input.nml
sed -i 's/na_init = 1/na_init = 0/g' input.nml
sed -i 's/external_ic = .true./external_ic = .false./g' input.nml
sed -i 's/nggps_ic = .true./nggps_ic = .false./g' input.nml
sed -i 's/mountain = .false./mountain = .true./g' input.nml
sed -i '/fv_core_nml/a\  ignore_rst_cksum = .true.' input.nml
sed -i '/&fms_nml/i \
&fms_io_nml\
  checksum_required = .false.\
/' input.nml

#mpiexec -n 6 $builddir/ufs-weather-model/src/ufs-weather-model-build/ufs_model
#cd $builddir/ufs-weather-model/src/ufs-weather-model-build/ufs_model


