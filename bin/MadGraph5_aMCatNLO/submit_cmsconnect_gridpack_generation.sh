#!/bin/bash

source cmsconnect_utils.sh

create_codegen_jdl(){
cat<<-EOF
	Universe = vanilla 
	Executable = $codegen_exe
	Arguments = $card_name $card_dir
	
	Error = condor_log/job.err.\$(Cluster)-\$(Process) 
	Output = condor_log/job.out.\$(Cluster)-\$(Process) 
	Log = condor_log/job.log.\$(Cluster) 
	
	transfer_input_files = $input_files, gridpack_generation.sh
	transfer_output_files = ${card_name}.log
	transfer_output_remaps = "${card_name}.log = ${card_name}_codegen.log"
	+WantIOProxy=true
	
	+REQUIRED_OS = "rhel6"
	request_cpus = $cores
	request_memory = $memory
	Queue 1
EOF
}

create_codegen_exe(){
cat<<-EOF
	#! /bin/bash

	# Condor scratch dir
	condor_scratch=\$(pwd)
	echo "\$condor_scratch" > _condor_scratch_dir.txt

	# Untar input files
	tar xfz "$input_files"
	
	# Setup CMS framework
	export VO_CMS_SW_DIR=/cvmfs/cms.cern.ch
	source \$VO_CMS_SW_DIR/cmsset_default.sh
	
	# Run
	iscmsconnect=1 bash -x gridpack_generation.sh "${card_name}" "${card_dir}" "${workqueue}" CODEGEN "${scram_arch}" "${cmssw_version}"
	exitcode=\$?

	if [ \$exitcode -ne 0 ]; then
	    echo "Something went wrong while running CODEGEN step. Exiting now."
	    exit \$exitcode
	fi

	# Pack output and condor scratch dir info
	cd "\${condor_scratch}/${card_name}"
	mv "\${condor_scratch}/_condor_scratch_dir.txt" .
	XZ_OPT="--lzma2=preset=9,dict=512MiB" tar -cJpsf "\${condor_scratch}/${sandbox_output}" "${card_name}_gridpack" "_condor_scratch_dir.txt"
	# tar -jcf "\${condor_scratch}/$sandbox_output" "${card_name}_gridpack" "_condor_scratch_dir.txt"

	# Stage-out sandbox
	# First, try XRootD via stash.osgconnect.net
	echo ">> Copying sandbox via XRootD"
	xrdcp -f "\${condor_scratch}/$sandbox_output" "root://stash.osgconnect.net:1094/${stash_tmpdir##/stash}/$sandbox_output"
	exitcode=\$?
	if [ \$exitcode -eq 0 ]; then
	    exit 0
	else
	    echo "The xrdcp command below failed:"
	    echo "xrdcp -f \${condor_scratch}$sandbox_output root://stash.osgconnect.net:1094/${stash_tmpdir##/stash}/$sandbox_output"
	fi
	# Second, try condor_chirp
	echo ">> Copying sandbox via condor_chirp"
	if [ -n "\${CONDOR_CONFIG}" ]; then
	    CONDOR_CHIRP_BIN="\$(dirname \$CONDOR_CONFIG)/main/condor/libexec/condor_chirp"
	    "\${CONDOR_CHIRP_BIN}" put -perm 644 "\${condor_scratch}/$sandbox_output" "$sandbox_output"
	    exitcode=\$?
	fi
	if [ \$exitcode -ne 0 ]; then
	    echo "condor_chirp failed. Exiting with error code 210."
	    exit 210
	fi
	rm "\${condor_scratch}/$sandbox_output"

EOF
}

card_name=$1
card_dir=$2
workqueue="condor"
# How many cores and how much memory should we request for the CODEGEN step condor job?
# Using 1 core and 2 Gb by default.
cores="${3:-1}"
memory="${4:-2 Gb}"
scram_arch=${3}
cmssw_version=${4}

parent_dir=$PWD
##############################################
# CODEGEN step
##############################################
echo ">> Start CODEGEN step"
## Name of codegen condor executable and submit files
codegen_exe="codegen_${card_name}.sh"
codegen_jdl="codegen_${card_name}.jdl"

# Tarball workflow cards and Madgraph patches.
# Those will be input files for the condor CODEGEN step.
input_files="input_${card_name}.tar.gz"
patches_directory="./patches"

if [ -e "$input_files" ]; then rm "$input_files"; fi
tar -zcf "$input_files" "$card_dir" "$patches_directory"

## Create a submit file for a single job
# create_codegen_exe arguments are:
# - input_files, card_name, card_dir, workqueue, sandbox_output, cores, memory
# create_codegen_jdl arguments are:
# - codegen_exe, card_name, input_files, sandbox_output, cores, memory

sandbox_output="${card_name}_output.tar.xz"

# Clean up old files first, just in case.
if [ -e "$sandbox_output" ]; then rm -f "$sandbox_output"; fi
if [ -e "${card_name}_codegen.log" ]; then rm "${card_name}_codegen.log"; fi

# Create a temp directory in user's stash area.
# Modify permissions so that XRootD can write to it.
# @TODO: Find a better way to do this.
stash_tmpdir=$(mktemp -d --tmpdir=/stash/user/$USER)
chmod 777 "$stash_tmpdir"

create_codegen_exe > "$codegen_exe"
chmod +x $codegen_exe
create_codegen_jdl > "$codegen_jdl"

# Submit condor job and wait for it to finish
echo ">> Submitting CODEGEN condor job and wait"
mkdir -p condor_log
CLUSTER_ID=$(condor_submit "${codegen_jdl}" | tail -n1 | rev | cut -d' ' -f1 | rev)
LOG_FILE=$(condor_q -format '%s\n' UserLog $CLUSTER_ID | tail -n1)
condor_wait "$LOG_FILE" "$CLUSTER_ID"
condor_exitcode=$(condor_history ${CLUSTERID} -limit 1 -format "%s" ExitCode)

# Check condor job exit code before going to the next step
#if [ "x$condor_exitcode" != "x0" ] || [ ! -f "$sandbox_output" ]; then
if [ "x$condor_exitcode" != "x0" ]; then
    echo "CODEGEN condor job failed. Please, check logfiles in condor_log/ directory (Job Id: $CLUSTER_ID)". Exiting now.
    exit $condor_exitcode
fi

# Check sandbox
if [ -f "$stash_tmpdir/$sandbox_output" ]; then
    mv "$stash_tmpdir/$sandbox_output" "$parent_dir"
    rmdir "$stash_tmpdir"
fi

if [ ! -f "$sandbox_output" ]; then
    if [ -d "$stash_tmpdir" ]; then rmdir "$stash_tmpdir"; fi
    echo "CODEGEN condor job sandbox output could not be located. Exiting now."
    exit 210
fi

echo "CODEGEN ran sucessfully!."

# Clean up condor exe, jdl and condor logfiles.
rm "$codegen_exe" "$codegen_jdl"
rm condor_log/job.*.${CLUSTER_ID%%.}-* condor_log/job.log.${CLUSTER_ID%%.}

# Clean up input files
rm "$input_files"

## Extract sandbox
mkdir -p "$card_name"
mv "$sandbox_output" "$card_name"
cd "$card_name"
echo ">>Extracting sandbox from CODEGEN step"
cmssw_setup "$sandbox_output"
cd -

##############################################
# INTEGRATE step
##############################################
# CMS Connect CMS Dashboard reporting is not yet
# compatible with Madgraph condor submission
# Temporarily disable dashboard reporting

echo ">> Start INTEGRATE step"
cd "$parent_dir"

# CMS Dashboard reporting not yet working with this step.
export CONDOR_CMS_DASHBOARD=False
iscmsconnect=1 bash -x gridpack_generation.sh ${card_name} ${card_dir} ${workqueue} INTEGRATE ${scram_arch} ${cmssw_version}

##############################################
# MADSPIN step
# @TODO: This hasn't been split from INTEGRATE
# step yet.
##############################################
#echo ">> Start MADSPIN step"
#iscmsconnect=1 bash -xe gridpack_generation.sh ${card_name} ${card_dir} ${workqueue} MADSPIN ${scram_arch} ${cmssw_version}
