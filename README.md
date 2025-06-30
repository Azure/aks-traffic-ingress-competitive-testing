# AKS Traffic Ingress Competitive Testing

Collection of common scripts and tooling to be used by AKS Ingress competitive testing.

Note that this repo assumes that [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/), [helm](https://helm.sh/docs/intro/install/), and [jq](https://jqlang.org/download/) are already installed.

## Verifying locally

We verify that scripts work locally before making changes and also add automated testing to ensure scripts work.

For example, to ensure that the simple RPS is working locally we can use the following commands

```bash
echo "Installing dependencies"
chmod +x ./modules/kind/install/install.sh
chmod +x ./modules/vegeta/install/install.sh
./modules/kind/install/install.sh
./modules/vegeta/install/install.sh

echo "Creating Kind cluster"
chmod +x ./modules/kind/run/run.sh
./modules/kind/run/run.sh

echo "Get outputs from cluster"
chmod +x ./modules/kind/output/output.sh
INGRESS_CLASS=$(./modules/kind/output/output.sh ingress_class)
INGRESS_URL=$(./modules/kind/output/output.sh ingress_url)

echo "Applying manifests"
helm install server ./charts/server \
    --namespace server \
    --create-namespace \
    --set ingress.enabled=true \
    --set ingress.className=$INGRESS_CLASS \
    --wait

echo "Running RPS test"
chmod +x ./modules/vegeta/run/run.sh
./modules/vegeta/run/run.sh http://localhost:8080 50 30s 10
chmod +x ./modules/vegeta/output/output.sh
./modules/vegeta/output/output.sh
```

## Repository Structure

This repository is a collection of modules that follow consistent patterns to create a common framework for Ingress competitive testing.

### /charts

[/charts](./charts/) contains the Helm charts to install Kubernetes resources.

### /modules

[/modules](./modules/) contains groupings of tools each with the following sub directories and files
- README.md in each module contains information on how the module works and what it accomplishes
- /install contains a `install.sh` script that installs the required tool
- /run contains scripts that run the tool. These can be functions and modules can contain many different functions for running
- /output collects the output of the run into a standardized json file

Note: all modules expect to be **run from the root directory of this project**.

### /server

[/server](./server/) contains the files required to run a web server and containerize it. Learn more [here](./server/README.md).

## Notice

Trademarks This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft trademarks or logos is subject to and must follow Microsoft’s Trademark & Brand Guidelines. Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship. Any use of third-party trademarks or logos are subject to those third-party’s policies.
