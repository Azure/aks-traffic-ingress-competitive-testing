# AKS Traffic Ingress Competitive Testing

Collection of common scripts and tooling to be used by AKS Ingress competitive testing.

Note that this repo assumes that [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/), [helm](https://helm.sh/docs/intro/install/), Go and [jq](https://jqlang.org/download/) are already installed.

## Verifying locally

We verify that scripts work locally before making changes and also add automated testing to ensure scripts work.

The `scripts/master.sh` script orchestrates the full test pipeline: creating a Kind cluster, installing tools, deploying the server, and running a scenario. To run a basic RPS test locally:

```bash
chmod +x ./scripts/master.sh
./scripts/master.sh \
  --traffic ingress \
  --scenario basic-rps \
  --rate 50 \
  --duration 30s \
  --output-file ./results/basic_rps.json
```

To test with the Gateway API (Istio) instead of Ingress (nginx):

```bash
./scripts/master.sh \
  --traffic gateway \
  --scenario basic-rps \
  --rate 50 \
  --duration 30s \
  --output-file ./results/gateway_basic_rps.json
```

To run the restarting backend scenario:

```bash
./scripts/master.sh \
  --traffic ingress \
  --scenario restarting-backend-rps \
  --rate 50 \
  --duration 90s \
  --output-file ./results/restarting_backend_rps.json
```

The master script handles cluster cleanup automatically on exit. Run `./scripts/master.sh --help` for all available options.

## Server scheduling options

The server setup scripts support deploy-time placement for the server workload:

- `--node-selector <key=value>` adds a single node selector entry to the Helm release.
- `--tolerations-file <path>` passes an extra Helm values file to the chart.

`scripts/master.sh` also exposes these deployment flags and adds `--kind-topology <default|scheduling-e2e>`:

- `--kind-topology default` keeps the existing single-node Kind cluster.
- `--kind-topology scheduling-e2e` creates a second worker node labeled `scheduling=enabled` and tainted `scheduling=enabled:NoSchedule` for placement validation.
- When `--node-selector` is set, `scripts/master.sh` verifies that the server pods are scheduled only onto matching nodes before it runs the scenario.

The tolerations file is read by Helm as a values fragment, so it must be valid YAML with a top-level `tolerations:` key. Example:

```yaml
tolerations:
  - key: dedicated
    operator: Equal
    value: userpool
    effect: NoSchedule
```

Do not pass a bare YAML list such as `- key: ...`; the chart expects `.Values.tolerations`.

Examples:

```bash
./scripts/setup/ingress.sh \
  --ingress-class nginx \
  --replica-count 15 \
  --node-selector agentpool=userpool \
  --tolerations-file ./server-tolerations.yaml

./scripts/setup/gateway.sh \
  --gateway-class istio \
  --replica-count 15 \
  --node-selector agentpool=userpool \
  --tolerations-file ./server-tolerations.yaml

./scripts/master.sh \
  --traffic ingress \
  --scenario basic-rps \
  --kind-topology scheduling-e2e \
  --node-selector scheduling=enabled \
  --tolerations-file ./charts/server/ci-scheduling-values.yaml \
  --rate 50 \
  --duration 30s \
  --output-file ./results/scheduling_ingress_basic.json
```

When these flags are omitted, the setup scripts and `scripts/master.sh` behave as before.

## Docker

The Docker image provides access to all scripts via a routing entrypoint:

```bash
# Run the full test pipeline
docker run <image> master --traffic ingress --scenario basic-rps

# Run a scenario directly
docker run <image> scenario/basic_rps --ingress-url http://localhost:8080 --rate 50 --duration 30s

# Run install/setup scripts
docker run <image> install/nginx
docker run <image> setup/ingress --ingress-class nginx --replica-count 3

# Bulk-create dns-test Ingresses or HTTPRoutes (for external-DNS testing)
docker run <image> setup/dns-ingresses --count 100 --domain extdns.telescope.test
docker run <image> setup/dns-httproutes --count 100 --domain extdns.telescope.test
# Append a second batch of 100 starting at index 101 (no hostname collisions)
docker run <image> setup/dns-ingresses --count 100 --existing-n 100 --domain extdns.telescope.test
docker run <image> cleanup/dns-ingresses
docker run <image> cleanup/dns-httproutes

# Run module scripts
docker run <image> module/vegeta/install
docker run <image> module/vegeta/run --target-url http://localhost:8080 --rate 50 --duration 30s
docker run <image> module/kind/output host_port

# Merge multiple vegeta .bin files into per-second JSON
docker run <image> merge --output-file merged.json pod0.bin pod1.bin pod2.bin

# Run the server
docker run -p 3333:3333 <image> server
```

Run the image with no arguments to see all available commands.

## Repository Structure

This repository is a collection of modules that follow consistent patterns to create a common framework for Ingress competitive testing.

### /charts

[/charts](./charts/) contains the Helm charts to install Kubernetes resources.

### /modules

[/modules](./modules/) contains groupings of tools each with the following sub directories and files
- README.md in each module contains information on how the module works and what it accomplishes
- /install contains a `install.sh` script that installs the required tool
- /run contains `run.sh` that run the tool. These can be functions and modules can contain many different functions for running
- /output collects the output of the run into a standardized json file
- /merge (vegeta only) merges multiple raw `.bin` files from parallel pods into unified per-second JSON output
- /test contains a `test.sh` script that tests and validates the module is working correctly

Note: all modules expect to be **run from the root directory of this project**.

### /scripts

[/scripts](./scripts/) contains the orchestration and setup scripts:
- `master.sh` — the main entry point that runs the full test pipeline
- `/install` — traffic controller install scripts (`nginx.sh`, `istio.sh`)
- `/setup` — server deployment scripts with readiness checks (`ingress.sh`, `gateway.sh`)
- `/scenarios` — load test scenario scripts. These assume the cluster, traffic controller, and server are already running. Their output is JSON so that consumers can decide on the final display format themselves.
- `/setup/dns-ingresses.sh`, `/setup/dns-httproutes.sh` — bulk-create N `Ingress` or Gateway API `HTTPRoute` resources (each with a unique `test-{i}.{domain}` hostname, all labeled `dns-test=true`) for external-DNS reconciliation testing. Use `--existing-n <N>` to offset the index range so additional batches can be appended without colliding with existing hostnames. The generated manifest is written to a unique `mktemp` file under `$TMPDIR` and applied with a single `kubectl apply --server-side -f`. Paired with `/cleanup/dns-ingresses.sh` and `/cleanup/dns-httproutes.sh`, which delete by label.

### /server

[/server](./server/) contains the files required to run a web server and containerize it. Learn more [here](./server/README.md).

## Release 

Update the [CHANGELOG.md](./CHANGELOG.md) to contain the new release. After the CHANGELOG has been updated and merged, you can start a release by going to the `Actions` tab and selecting `Release` on the left. Then click `Run workflow` and input the required parameters. It's very important that the SHA used is one that matches the changes detailed in the CHANGELOG exactly.

You might need to release the image to your own registry as well. The following is an example for ACR.

```bash
# be sure to update version with the release you're pushing
VERSION="0.0.0"
az acr build --image traffic-competitive-testing:$VERSION \
    --registry telescope \
    --file Dockerfile .
```

## Notice

Trademarks This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft trademarks or logos is subject to and must follow Microsoft’s Trademark & Brand Guidelines. Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship. Any use of third-party trademarks or logos are subject to those third-party’s policies.
