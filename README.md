# Apica Ascent Helm Charts

These charts are used to deploy Apica Ascent on Kubernetes.

## Creating Releases

1. Change the `version` value in `apica-ascent/Chart.yaml`.
1. Set `appVersion` to match the Ascent release indicated by the Flash and
Coffee tags in `apica-ascent/values.yaml`.
1. Run `helm package apica-ascent` from the top-level directory. This will
generate a new tarball.
1. Run `helm repo index .` from the top-level directory. This will update
`index.yaml` so clients see the new version.
1. Open a pull request to get the changes merged.
1. Once the PR is merged, create an annotated tag matching the release version
and push it.
   ```
   git tag -a <semver> <commit-hash> -m "Release <semver>"
   git push origin <semver>
   ```
1. Create a [Github
Release](https://github.com/ApicaSystem/apica-ascent-helm/releases).
  * Use the previous release tag to generate release notes. Edit release notes for clarity
(e.g., remove Jira ticket references from descriptions). 
  * Name it `apica-ascent v<semver>`
