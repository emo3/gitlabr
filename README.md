# Local GitLab Runner notes

This directory deploys a standalone GitLab Runner for the sibling `../gitlabc`
GitLab chart install.

`../gitlabc/scripts/deploy_gitlab.sh` intentionally uses
`gitlab-runner.install=false`, so the runner is managed here as a separate Helm
release.

## Quick start

Make sure the local GitLab install is healthy:

```bash
cd $HOME/code/gitlabc
bash scripts/check_status.sh
```

Open GitLab:

```text
https://gitlab.127.0.0.1.nip.io/users/sign_in
```

Create an instance, group, or project runner in GitLab first:

- Instance runner: Admin area > CI/CD > Runners > Create instance runner.
- Group runner: Group > Build > Runners > Create group runner.
- Project runner: Project > Settings > CI/CD > Runners > Create project runner.

For first local testing, prefer an instance runner or a group runner. Enable
untagged jobs, and add tags:

```text
k8s,local
```

Copy the runner authentication token shown by GitLab, save it in a local
ignored file, then deploy:

```bash
cd $HOME/code/gitlabr
kubectl --context k3d-gitlab-dev -n gitlab get secret dev-garage-gitlab-object-storage
cd $HOME/code/gitlabc
bash scripts/configure_k3d_registry_pull.sh
cd $HOME/code/gitlabr
mkdir -p .secrets
chmod 700 .secrets
printf '%s' 'glrt-REPLACE_ME' > .secrets/gitlab-runner-token
chmod 600 .secrets/gitlab-runner-token
GITLAB_RUNNER_TOKEN_FILE=.secrets/gitlab-runner-token bash scripts/deploy_runner.sh
bash scripts/check_runner.sh
```

The first deploy creates `.values/gitlab-runner.values.yaml` from
`.values/gitlab-runner.example.values.yaml`. Edit the generated file when you
want different tags, concurrency, default job image, or cache settings.

The runner itself registers against the in-cluster GitLab service:

```text
http://gitlab-webservice-default.gitlab.svc.cluster.local:8181
```

Build pods also use this in-cluster service for Git fetches through the runner
`clone_url` setting. Otherwise jobs try to clone from
`gitlab.127.0.0.1.nip.io`, where `127.0.0.1` means the job pod itself.

Use the HTTPS `gitlab.127.0.0.1.nip.io` URL for your browser.

Runner job pods use the `gdr` image directly:

```text
registry.127.0.0.1.nip.io/gitlab/gitlab-docker-runner:latest
```

`../gitlabc/scripts/configure_k3d_registry_pull.sh` makes k3d node image pulls
use the local GitLab HTTPS registry path. Do not use Docker-in-Docker for the
smoke test.

## Cache

The default values use the `runner-cache` Garage bucket created by
`../gitlabc/scripts/dev_dependencies.sh`. During deploy, `scripts/deploy_runner.sh`
reads the existing `dev-garage-gitlab-object-storage` secret and creates the
`gitlab-runner-garage-cache` secret expected by the GitLab Runner Helm chart.

This does not use AWS S3 buckets. GitLab Runner calls this cache backend `s3`
because Garage exposes an S3-compatible API, so the values file still contains
`Type = "s3"` and `[runners.cache.s3]`.

Run the GitLab dependency setup first if the Garage secret does not exist:

```bash
cd $HOME/code/gitlabc
bash scripts/dev_dependencies.sh setup
```

## Common commands

| Task | Command |
| --- | --- |
| Deploy runner | `GITLAB_RUNNER_TOKEN_FILE=.secrets/gitlab-runner-token bash scripts/deploy_runner.sh` |
| Check runner | `bash scripts/check_runner.sh` |
| Remove runner release | `bash scripts/reset_runner.sh` |

## Useful environment variables

| Variable | Default |
| --- | --- |
| `NAMESPACE` | `gitlab` |
| `RELEASE_NAME` | `gitlab-runner` |
| `KUBE_CONTEXT` | `k3d-gitlab-dev` |
| `RUNNER_VALUES_FILE` | `.values/gitlab-runner.values.yaml` |
| `RUNNER_CHART_VERSION` | latest available from the Helm repo |
| `GARAGE_RELEASE_NAME` | `dev-garage` |
| `GITLAB_REGISTRY_PULL_SECRET` | `gitlab-registry-pull` |
| `GITLAB_REGISTRY_HOST` | `registry.127.0.0.1.nip.io` |
| `GITLAB_RUNNER_TOKEN` | required unless `GITLAB_RUNNER_TOKEN_FILE` is set |
| `GITLAB_RUNNER_TOKEN_FILE` | unset |

## Smoke test

Add this `.gitlab-ci.yml` to a project that can use the runner:

```yaml
verify-tools:
  image: registry.127.0.0.1.nip.io/gitlab/gitlab-docker-runner:latest
  tags:
    - k8s
  script:
    - /usr/local/bin/verify-tools.sh
```

Run the pipeline and confirm the job completes.

If the runner does not pick up jobs:

```bash
cd $HOME/code/gitlabr
bash scripts/check_runner.sh
kubectl --context k3d-gitlab-dev -n gitlab get deployment
kubectl --context k3d-gitlab-dev -n gitlab logs deploy/gitlab-runner
```

The `deploy/gitlab-runner` log command assumes the default `RELEASE_NAME`.
Also verify in GitLab that the runner is not paused and that the project has
access to it.
