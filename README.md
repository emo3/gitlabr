# Local GitLab Runner notes

This directory deploys a standalone GitLab Runner for the sibling `../gitlabc`
GitLab chart install.

`../gitlabc/scripts/deploy_gitlab.sh` intentionally uses
`gitlab-runner.install=false`, so the runner is managed here as a separate Helm
release.

## Quick start

Create an instance, group, or project runner in GitLab first:

- Instance runner: Admin area > CI/CD > Runners > Create instance runner.
- Group runner: Group > Build > Runners > Create group runner.
- Project runner: Project > Settings > CI/CD > Runners > Create project runner.

Copy the runner authentication token shown by GitLab, then deploy:

```bash
cd $HOME/code/gitlabr
GITLAB_RUNNER_TOKEN='glrt-...' bash scripts/deploy_runner.sh
bash scripts/check_runner.sh
```

The first deploy creates `.values/gitlab-runner.values.yaml` from
`.values/gitlab-runner.example.values.yaml`. Edit the generated file when you
want different tags, concurrency, default job image, or cache settings.

## Cache

The default values use the `runner-cache` Garage bucket created by
`../gitlabc/scripts/dev_dependencies.sh`. During deploy, `scripts/deploy_runner.sh`
reads the existing `garage-gitlab-object-storage` secret and creates the
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
| Deploy runner | `GITLAB_RUNNER_TOKEN='glrt-...' bash scripts/deploy_runner.sh` |
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
| `GITLAB_RUNNER_TOKEN` | required unless `GITLAB_RUNNER_TOKEN_FILE` is set |
| `GITLAB_RUNNER_TOKEN_FILE` | unset |

## Smoke test

Add this `.gitlab-ci.yml` to a project that can use the runner:

```yaml
test-runner:
  image: alpine:latest
  tags:
    - k8s
  script:
    - echo "runner works"
    - uname -a
```
