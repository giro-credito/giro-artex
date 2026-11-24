# Giro ARTEX

This fork tracks [BaaRai/ARTEX](https://github.com/BaaRai/ARTEX). Giro's files live under `giro/` and in two workflow files, `.github/workflows/giro-overlay.yml` and `.github/workflows/giro-deploy.yml`. Everything else is upstream.

`giro/UPSTREAM_SHA` is the oldest upstream commit this branch has recorded. `giro/scripts/check-overlay.sh` fails when a path outside the overlay differs from that commit, or from a newer upstream commit already merged by Sync fork or `git merge upstream/main`. The overlay workflow runs that check on every push and pull request, with full git history. Sync fork does not move the pin, and production does not roll forward until the pin does.

## Sync

```bash
giro/scripts/sync-upstream.sh
```

That adds the `upstream` remote if it is missing, fetches `BaaRai/ARTEX`, merges `upstream/main`, and moves `giro/UPSTREAM_SHA` to the commit that was merged. It does not push. Pass a tag or commit when you want a pin other than `upstream/main`:

```bash
giro/scripts/sync-upstream.sh upstream/v1.2.3
```

A conflict outside `giro/` is a stop. Abort that merge. A conflict under `giro/` is ours to resolve, then finish with the commands the script prints.

Merging updates the pin, which is a change under `giro/`. Once deploy is enabled, that merge is what rolls the new upstream onto the instance. Until then it only updates the branch.

## Our own changes

Add files under `giro/`. CloudFormation, the Compose override, and the deploy scripts are already there.

A change to an upstream file does not get committed. Put it in `giro/patches/` as a `git format-patch` file. Names sort in apply order (`0001-something.patch`). The publish step syncs a clean tree and then runs `giro/scripts/apply-patches.sh`. The next sync replays the same files. A patch that no longer applies fails the overlay check, and that one patch is the thing to redo.

## Who can open the panel

The load balancer is internet-facing and has no rule for `0.0.0.0/0`. Port 80 and 443 accept the two current production Twingate connectors, `3.23.119.136/32` and `3.134.28.226/32`. The Web ACL allows those same addresses and blocks every other client. The instance has no public address, and its only inbound port is 8787 from that load balancer. Port 8788, the recording proxy, stays on the instance loopback. People sign in while connected to Twingate, the same way they open the other Giro admin sites.

## What a task is allowed to touch

This deployment is for pentesting Giro's own production. Container traffic may leave the instance only on ports 80 and 443, and only toward the names in `giro/egress/targets.txt`:

- `girocredito.com`
- `www.girocredito.com`
- `app.girocredito.com`
- `web.girocredito.com`

`giro/scripts/egress-lock.sh` resolves those names and installs the filter. It refuses `staging.girocredito.com`, anything under it, and `artex.girocredito.com`. It also refuses a name outside `girocredito.com`. A resolved private, link-local, or metadata address is not added, so a task cannot open the VPC, RDS, or the instance role. The filter is refreshed every five minutes. A task with an empty scope in the panel is still held to this list.

The ARTEX process also needs a model API or a task cannot run. `giro/egress/platform.txt` allows `api.anthropic.com`, `api.openai.com`, and `openrouter.ai` on 443. Those are not targets, and the script rejects any other platform name. Every OpenRouter model is reached through `openrouter.ai`, so adding a model does not add a host.

The host itself is not filtered. The image build and Session Manager use that path. A rebuild opens the container filter for the build and puts it back when the build ends, including when the build fails.

## What the instance runs

One `t4g.xlarge` in `giro-private-subnet-1`. IMDSv2 is required and the hop limit is 1, so the container cannot read the instance role. Compose builds the upstream Dockerfile. Postgres, task data, and `keys/` are on the encrypted root volume. Daily snapshots keep 7 copies.

The site name is `artex.girocredito.com`. The database password is generated once in Secrets Manager. Replacing that secret does not change the Postgres role on an existing volume. ARTEX generates `keys/secret.key` itself. Losing the volume loses the signing key and the sealed secrets. `CpuCredits` stays `standard`. A throttled first image build is the signal to deploy once with `unlimited`, then put it back.

The unhealthy-host alarm fires during that first build. `/api/health` starts answering when the container is up.

## Turn deploy on

The workflow lints on a giro change and does not deploy until all three exist:

1. The GitHub environment `production`.
2. Stack `giro-artex-github-oidc`, applied once from the laptop. It trusts this repository on `main` and only `giro-deploy.yml`. It does not create a second OIDC provider.

```bash
aws sso login --profile giro-admin
aws cloudformation deploy --profile giro-admin --region us-east-2 \
  --stack-name giro-artex-github-oidc \
  --template-file giro/cloudformation/github-oidc.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset
```

3. The repository variable `ARTEX_DEPLOY_ENABLED` set to `true`.

After that, a push to `main` that changes `giro/` assumes `giro-artex-github-deploy` and runs `giro/scripts/deploy.sh`. The same script from a laptop refuses any account other than `920373016063`. Publishing uploads this tree and rebuilds the image on the instance, so expect a long first build and a short outage on later ones.

Changing `AmiId` or `InstanceType` replaces the instance. Termination protection on the instance blocks that until you turn it off. The root volume has `DeleteOnTermination` false. Stack deletion is blocked until you disable stack termination protection and load balancer deletion protection.

```bash
aws ec2 modify-instance-attribute --profile giro-admin --region us-east-2 \
  --instance-id <id> --no-disable-api-termination
aws elbv2 modify-load-balancer-attributes --profile giro-admin --region us-east-2 \
  --load-balancer-arn <arn> \
  --attributes Key=deletion_protection.enabled,Value=false
aws cloudformation update-termination-protection --profile giro-admin --region us-east-2 \
  --stack-name giro-artex --no-enable-termination-protection
```

Session Manager:

```bash
aws ssm start-session --profile giro-admin --region us-east-2 --target <instance-id>
```

Logs on the instance: `journalctl -u artex` and `/var/log/cloud-init-output.log`.
