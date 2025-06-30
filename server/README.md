
# Server

Contains files required to run web server and containerize it.

GitHub Container Registry is our container registry. To trigger a build go to the GitHub repository then click `Actions` -> `Build and Push to GHCR` -> `Run workflow` -> ensure you're using workflow from main then click `Run workflow`

After triggering a build, update references to the container to use the new build.