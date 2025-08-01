# AKS Traffic Ingress Competitive Testing

Collection of common scripts and tooling to be used by AKS Ingress competitive testing.

Note that this repo assumes that [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/), [helm](https://helm.sh/docs/intro/install/), Go and [jq](https://jqlang.org/download/) are already installed.

## Verifying locally

We verify that scripts work locally before making changes and also add automated testing to ensure scripts work.

For example, to ensure that the simple RPS is working locally we can use the following commands

```bash
echo "Installing cluster dependencies"
chmod +x ./modules/kind/install/install.sh
chmod +x ./modules/jplot/install/install.sh

echo "Creating Kind cluster"
chmod +x ./modules/kind/run/run.sh
./modules/kind/run/run.sh

echo "Get outputs from cluster"
chmod +x ./modules/kind/output/output.sh
INGRESS_CLASS=$(./modules/kind/output/output.sh ingress_class)
INGRESS_URL=$(./modules/kind/output/output.sh ingress_url)

echo "Running basic RPS scenario"
chmod +x scenarios/basic_rps.sh
export INGRESS_CLASS="$INGRESS_CLASS"
export INGRESS_URL="$INGRESS_URL"
export RATE="50"
export DURATION="30s"
export WORKERS="10"
export REPLICA_COUNT="3"
export OUTPUT_FILE="./scenarios/results/basic_rps.json"
./scenarios/basic_rps.sh

# To test out the restarting backend scenario, run these commands instead
# echo "Running restarting backend RPS scenario"
# chmod +x scenarios/restarting_backend_rps.sh
# export INGRESS_CLASS="$INGRESS_CLASS"
# export INGRESS_URL="$INGRESS_URL"
# export RATE="50"
# export DURATION="90s"
# export WORKERS="10"
# export REPLICA_COUNT="5"
# export OUTPUT_FILE="./scenarios/results/restarting_backend_rps.json"
# ./scenarios/restarting_backend_rps.sh

chmod +x ./modules/vegeta/output/output.sh
chmod +x ./modules/jplot/run/run.sh
./modules/vegeta/output/output.sh | ./modules/jplot/run/run.sh vegeta
```

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

### /server

[/server](./server/) contains the files required to run a web server and containerize it. Learn more [here](./server/README.md).

### /scenarios

[/scenarios](./scenarios/) contains files that run tests. These scenarios assume that a Kubernetes cluster is set in the kubectl context. Their output is JSON so that consumers can decide on the final display format themselves.

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
