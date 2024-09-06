#!/usr/bin/env bash
# this script sets up inputs and sets dummy variables so that the first part of the ufs-weather-model run_test.py script will
# work on a generic system and generate the experiment directory that is used to run the ufs forecast regression tests.
set -x

echo "&ensemble_nml
 ensemble_size = 2
/
" >> Data/ModelRunDirs/UFS_warmstart_1/input.nml

cd Data/ModelRunDirs/UFS_warmstart_1/RESTART
for file in *tile*.nc; do new=`echo $file | sed 's/tile/ens_01.tile/g'`; ln -s $file $new; done
cd ../../UFS_warmstart_2/RESTART
for file in *tile*.nc; do new=`echo $file | sed 's/tile/ens_02.tile/g'`; ln -s $file $new; done

