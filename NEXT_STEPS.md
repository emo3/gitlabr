# Next steps for Sunday, July 5, 2026

Goal: deploy and verify a standalone GitLab Runner for the local `gitlabc`
GitLab install.

## 1. Start the local cluster if it is stopped

```bash
k3d cluster start gitlab-dev
cd $HOME/code/gitlabc
bash scripts/check_status.sh
```

If GitLab is not healthy, fix that before deploying the runner.

## 2. Create a runner in GitLab

Open:

```text
https://gitlab.127.0.0.1.nip.io/users/sign_in
```

Use one of these:

- Instance runner: Admin area > CI/CD > Runners > Create instance runner.
- Group runner: Group > Build > Runners > Create group runner.
- Project runner: Project > Settings > CI/CD > Runners > Create project runner.

For first local testing, prefer an instance runner or a group runner for the
default imported-project group. Enable untagged jobs, and add tags:

```text
k8s,local
```

Copy the runner authentication token. It usually starts with:

```text
glrt-
```

## 3. Deploy the runner

```bash
cd $HOME/code/gitlabr
GITLAB_RUNNER_TOKEN='glrt-REPLACE_ME' bash scripts/deploy_runner.sh
bash scripts/check_runner.sh
```

The deploy script uses Garage for runner cache through the in-cluster
S3-compatible API. This is not AWS S3.

## 4. Smoke test a pipeline

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

Run the pipeline and confirm the job completes.

## 5. If the runner does not pick up jobs

Check:

```bash
cd $HOME/code/gitlabr
bash scripts/check_runner.sh
kubectl --context k3d-gitlab-dev -n gitlab logs deploy/gitlab-runner
```

Also verify the runner scope in GitLab:

- It is not paused.
- It allows untagged jobs, or the job uses the `k8s` tag.
- The project/group has access to the runner.

## Current repo state

`gitlabr` has been pushed to:

```text
git@github.com:emo3/gitlabr.git
```

Branch:

```text
main
```
