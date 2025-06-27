# AKS Traffic Ingress Competitive Testing

Collection of common scripts and tooling to be used by AKS Ingress competitive testing.

Note that this repo assumes that kubectl is already installed.

## Repository Structure

This repository is a collection of modules that follow consistent patterns to create a common framework for Ingress competitive testing.

### /modules

[/modules](./modules/) contains groupings of tools each with the following sub directories and files
- README.md in each module contains information on how the module works and what it accomplishes
- /install contains a `install.sh` script that installs the required tool
- /run contains scripts that run the tool. These can be functions and modules can contain many different functions for running
- /collect collects the output of the run into a standardized json file

All modules expect to be run from the root directory of this project.