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

# Run module scripts
docker run <image> module/vegeta/install
docker run <image> module/vegeta/run --target-url http://localhost:8080 --rate 50 --duration 30s
docker run <image> module/kind/output host_port

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
- /test contains a `test.sh` script that tests and validates the module is working correctly

Note: all modules expect to be **run from the root directory of this project**.

### /scripts

[/scripts](./scripts/) contains the orchestration and setup scripts:
- `master.sh` — the main entry point that runs the full test pipeline
- `/install` — traffic controller install scripts (`nginx.sh`, `istio.sh`)
- `/setup` — server deployment scripts with readiness checks (`ingress.sh`, `gateway.sh`)
- `/scenarios` — load test scenario scripts. These assume the cluster, traffic controller, and server are already running. Their output is JSON so that consumers can decide on the final display format themselves.

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
