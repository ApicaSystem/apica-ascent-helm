# Apica Ascent Helm Charts

These charts are used to deploy Apica Ascent on Kubernetes.

## Updating Version

When updating the chart version:
1. Change the `version` value in `apica-ascent/Chart.yaml`.
1. Run `helm package apica-ascent` from the top-level directory. This will
generate a new tarball.
1. Run `helm repo index .` from the top-level directory. This will update
`index.yaml` so clients see the new version.
1. Open a pull request to get the changes merged.
