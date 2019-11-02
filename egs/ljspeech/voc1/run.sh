#!/bin/bash

# Copyright 2019 Tomoki Hayashi
#  MIT License (https://opensource.org/licenses/MIT)

. ./cmd.sh || exit 1;
. ./path.sh || exit 1;

# basic settings
stage=-1
stop_stage=100
verbose=1
nj=16

# config
config=conf/parallel_wavegan.v1.yaml

# directory path setting
download_dir=downloads
dumpdir=dump

# training related setting
tag=""
resume=""

# decoding related setting
checkpoint=""

# shellcheck disable=SC1091
. parse_options.sh || exit 1;

train_set="train_nodev"
dev_set="dev"
eval_set="eval"

set -euo pipefail

if [ "${stage}" -le -1 ] && [ "${stop_stage}" -ge -1 ]; then
    echo "Stage -1: Data download"
    local/data_download.sh "${download_dir}"
fi

if [ "${stage}" -le 0 ] && [ "${stop_stage}" -ge 0 ]; then
    echo "Stage 0: Data preparation"
    local/data_prep.sh \
        --train_set "${train_set}" \
        --dev_set "${dev_set}" \
        --eval_set "${eval_set}" \
        "${download_dir}/LJSpeech-1.1" data
fi

if [ "${stage}" -le 1 ] && [ "${stop_stage}" -ge 1 ]; then
    echo "Stage 1: Feature extraction"
    # extract raw features
    pids=()
    for name in train_nodev dev eval; do
    (
        [ ! -e "${dumpdir}/${name}/raw" ] && mkdir -p "${dumpdir}/${name}/raw"
        ${train_cmd} --num-threads "${nj}" "${dumpdir}/${name}/raw/preprocessing.log" \
            preprocessing.py \
                --config "${config}" \
                --wavscp "data/${name}/wav.scp" \
                --dumpdir "${dumpdir}/${name}/raw" \
                --n_jobs "${nj}" \
                --verbose "${verbose}"
        echo "successfully finished feature extraction of ${name} set."
    ) &
    pids+=($!)
    done
    i=0; for pid in "${pids[@]}"; do wait "${pid}" || ((++i)); done
    [ "${i}" -gt 0 ] && echo "$0: ${i} background jobs are failed." && false
    echo "successfully finished feature extraction."

    # calculate statistics for normalization
    ${train_cmd} "${dumpdir}/train_nodev/compute_statistics.log" \
        compute_statistics.py \
            --config "${config}" \
            --rootdir "${dumpdir}/train_nodev/raw" \
            --dumpdir "${dumpdir}/train_nodev" \
            --verbose "${verbose}"
    echo "successfully finished calculation of statistics."

    # normalize and dump them
    pids=()
    for name in train_nodev dev eval; do
    (
        [ ! -e "${dumpdir}/${name}/norm" ] && mkdir -p "${dumpdir}/${name}/norm"
        ${train_cmd} --num-threads "${nj}" "${dumpdir}/${name}/norm/normalize.log" \
            normalize.py \
                --config "${config}" \
                --stats "${dumpdir}/train_nodev/stats.h5" \
                --rootdir "${dumpdir}/${name}/raw" \
                --dumpdir "${dumpdir}/${name}/norm" \
                --n_jobs "${nj}" \
                --verbose "${verbose}"
        echo "successfully finished normalization of ${name} set."
    ) &
    pids+=($!)
    done
    i=0; for pid in "${pids[@]}"; do wait "${pid}" || ((++i)); done
    [ "${i}" -gt 0 ] && echo "$0: ${i} background jobs are failed." && false
    echo "successfully finished normalization."
fi

if [ -z "${tag}" ]; then
    expdir="exp/train_ljspeech_$(basename "${config}" .yml)"
else
    expdir="exp/train_ljspeech_${tag}"
fi
if [ "${stage}" -le 2 ] && [ "${stop_stage}" -ge 2 ]; then
    echo "Stage 2: Network training"
    [ ! -e "${expdir}" ] && mkdir -p "${expdir}"
    ${cuda_cmd} --gpu 1 "${expdir}/train.log" \
        train.py \
            --config "${config}" \
            --train-dumpdir "${dumpdir}/train_nodev/norm" \
            --dev-dumpdir "${dumpdir}/dev/norm" \
            --outdir "${expdir}" \
            --resume "${resume}" \
            --verbose "${verbose}"
    echo "successfully finished training."
fi

if [ "${stage}" -le 3 ] && [ "${stop_stage}" -ge 3 ]; then
    echo "Stage 3: Network decoding"
    [ -z "${checkpoint}" ] && checkpoint="$(find "${expdir}" -name "*.pkl" -print0 | xargs -0 ls -t | head -n 1)"
    outdir="${expdir}/wav/$(basename "${checkpoint}" .pkl)"
    pids=()
    for name in dev eval; do
    (
        [ ! -e "${outdir}/${name}" ] && mkdir -p "${outdir}/${name}"
        ${cuda_cmd} --gpu 1 "${outdir}/${name}/decode.log" \
            decode.py \
                --dumpdir "${dumpdir}/${name}/norm" \
                --checkpoint "${checkpoint}" \
                --outdir "${outdir}/${name}" \
                --verbose "${verbose}"
        echo "successfully finished decoding of ${name} set."
    ) &
    pids+=($!)
    done
    i=0; for pid in "${pids[@]}"; do wait "${pid}" || ((++i)); done
    [ "${i}" -gt 0 ] && echo "$0: ${i} background jobs are failed." && false
    echo "successfully finished decoding."
fi
echo "finished."