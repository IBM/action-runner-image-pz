### **LXD Image Used by GitHub Actions Runner**

This section outlines the steps to build the components required for a GitHub-hosted Actions runner using LXD. Follow these instructions to prepare the environment and execute the build process.

---

### **Prerequisites**

1. **Install LXD**  
   - **Via Snap**:  
     Install LXD using Snap with the following command:  
     ```bash
     snap install lxd --classic
     ```
   - **Via APT (Ubuntu)**:  
     Alternatively, install LXD as a package available in the repository:  
     ```bash
     sudo apt update
     sudo apt install lxd
     ```

2. **Initialize LXD**  
   - You can initialize LXD interactively or through a preseed file for automated configuration.  

   **Interactive Initialization:**  
   Run the command and follow the prompts to configure LXD based on your preferences:  
   ```bash
   lxd init
   ```  

   **Automated Initialization:**  
   Create a file named `lxd-preseed.yaml` with the following content to automate the initialization process:  
   ```yaml
   config: {}
   cluster: null
   networks:
     - config:
         ipv4.address: auto
         ipv6.address: auto
       description: "action-runner-image-pz network"
       name: lxdbr0
       type: ""
   storage_pools:
     - config: {}
       description: "action-runner-image-pz storage pool"
       name: default
       driver: dir
   profiles:
     - config: {}
       description: "action-runner-image-pz"
       devices:
         eth0:
           name: eth0
           nictype: bridged
           parent: lxdbr0
           type: nic
         root:
           path: /
           pool: default
           type: disk
       name: default
   ```
   Use the following command to apply the preseed configuration:  
   ```bash
   lxd init --preseed < lxd-preseed.yaml
   ```

---

### **Building the GitHub Actions Runner Image**

After setting up LXD, execute the `lxd.sh` script to build the components for the GitHub Actions runner.  

1. Navigate to the script's directory:  
   ```bash
   cd /path/to/action-runner-image-pz/
   ```

2. Execute the build script:  
   ```
    sudo ./scripts/lxd.sh <os> <version> <setup_type>
   ```
The script will handle the required steps to configure the environment and build the LXD image used by the Actions runner.

---

### **Next Steps: Configure and Start the Runner**

Once the LXD image has been built successfully, follow these steps to create, configure and launch the GitHub Actions runner inside the container.

1. Create the runner container
   Use `lxd launch` to create the runner container from the image built in the previous step.
   ```bash
   lxd launch <container-name> <image-name>
   ```
   You can use additional flags based on your requirements (privileged vs non-privileged, nested virtualization etc.)
    
2. Exec into the LXD Container
   Use `lxc exec` to open a shell inside the container and switch immediately to the `runner` user:
   ```bash
   lxc exec <container-name> -- su - runner
   ```

3. Once you are in the runner userspace, you can cd to the `/opt/runner-cache` directory which should host all the necessary files for creating a self-hosted GitHub Actions runner.
   ```bash
   cd /opt/runner-cache
   ls
   ```
4. Now, to establish this as a self-hosted runner, navigate to your GitHub repo where you want this setup and go to it's settings page. Here, under Actions>Runners tab, you can create a
   new self-hosted runner. Select `Linux, x86` as your option and copy the `./config.sh` line along with the token. This token is necessary for linking the self-hosted runner with the repo.
   ```bash
   ./config.sh --url https://github.com/<org>/<repo> --token <token>
   ```
   You can find additional information on runner configuration in the [official GitHub documentation](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners#adding-a-self-hosted-runner-to-a-repository)
5. Post runner configuration, you are now all set to running your first workflow on Power/Z architecture!
   Just execute the `run.sh` script which activates the listener for the runner service and starts an active HTTP-poll session between GitHub and your runner.
   Make sure to use the correct `runs-on:` label (used during convifguration of the runner) in your workflow to direct the payload to the LXD runner.


### **Key Notes**

- Ensure that the required permissions and tools are available before running the script.
- For troubleshooting LXD initialization or network configurations, refer to the [official LXD documentation](https://linuxcontainers.org/lxd/docs/).
