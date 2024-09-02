#!/bin/bash
source $HOME/mambaforge/etc/profile.d/conda.sh
conda activate quetz
export FORWARDED_ALLOW_IPS='*'
quetz start quetz_server --host 0.0.0.0 --reload --proxy-headers
