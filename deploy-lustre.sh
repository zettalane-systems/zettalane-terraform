#!/bin/bash
# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

#
# MOVED — the Lustre deploy front end now lives in its own repository.
#
# This copy is retired rather than deleted so that an existing checkout, a bookmark or a
# stale copy of the docs lands on directions instead of "no such file or directory".
# The previous contents remain in this repository's history.
#
# Why it moved: deploy-lustre.sh, the Lustre client installer and their documentation are
# a product front end with its own release cadence and its own audience. This repository
# is the terraform modules that front end drives. Keeping both here meant every change to
# either churned the same repo, and the copy that shipped drifted from the one being
# maintained.

cat >&2 <<'EOF'

  deploy-lustre.sh has moved to its own repository. To carry on using it:

      git clone https://github.com/zettalane-systems/open-lustre-cloud.git
      cd open-lustre-cloud
      ./deploy-lustre.sh --help

  Read that repository's README for the supported clouds, the options and the
  worked examples. It clones these terraform modules on first run, so nothing
  here is wasted — the modules are still what does the work.

  To drive the modules directly instead, skip the front end entirely:

      cd <cloud>/mayanas          # aws, azure or gcp
      cp terraform.tfvars.example terraform.tfvars
      terraform init && terraform apply

EOF
exit 1
