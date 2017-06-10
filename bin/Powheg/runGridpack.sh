#!/bin/bash

GRIDPACK=${1}
LOCALDIR=${2}
TAG=${3}
SEED=${4}

echo "Creating project"
scram project CMSSW_7_1_27
cd CMSSW_7_1_27/src
eval `scram r -sh`

echo "@ `pwd` unpacking gridpack"
cp ${GRIDPACK} ./mygridpack.tgz
gtar xzvf mygridpack.tgz

echo "Generating events"
./runcmsgrid.sh 50000 ${SEED} 4

echo "Copying to SE"
OUTDIR=/store/group/phys_heavyions/anstahll/W_8160GeV/${TAG}
a=(`ls ${LOCALDIR}/*.lhe`)
for i in ${a[@]}; do
    echo "      ${i}"
    outfile=`basename ${i}`
    xrdcp ${LOCALDIR}/${outfile} root://eoscms//eos/cms/${OUTDIR}/seed_${SEED}_${outfile};
done

echo "All done, cleaning up"
cd -
rm -rf CMSSW_7_1_27
