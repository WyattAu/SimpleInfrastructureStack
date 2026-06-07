# Windows 11 Forgejo Runner Runbook

## 1. Architecture

### Purpose

A Windows 11 VM running as a Forgejo Actions runner, providing Windows-native build/test environments for CI/CD pipelines. It handles jobs labeled `windows-latest` that require Windows-specific tooling (PowerShell, .NET, Visual Studio, etc.).

### Infrastructure

| Component | Detail |
|---|---|
| Host | CachyOS at 192.168.1.191 (Incus hypervisor) |
| VM Name | win11 |
| VM IP | 10.136.57.35 (Incus bridge) |
| Host access | 192.168.1.3 (TrueNAS, reachable by IP) |
| DNS | Must be set manually to 8.8.8.8 (Incus bridge has no internet DNS) |
| OS | Windows 11 Pro Build 26200 |
| Runner Binary | C:\forgejo-runner\forgejo-runner.exe v12.10.1 (Crown0815 GitHub mirror) |
| Service | NSSM-managed "ForgejoRunner" (SERVICE_AUTO_START) |
| Docker | Windows containers mode (not Linux containers) |
| Runner labels | `["windows-latest"]` only |

### Why It Exists

Forgejo Actions jobs that need a Windows environment cannot run on the existing Linux runner. This VM provides an isolated Windows environment with Docker (Windows containers) so that workflows like .NET builds, Windows-specific packaging, and Windows integration tests can execute natively.

## 2. Initial Setup

### Prerequisites

- CachyOS host with Incus installed and configured (192.168.1.191)
- Windows 11 Pro ISO
- Network bridge capable of assigning IPs in the 10.136.57.0/24 range
- Forgejo instance accessible from the VM network
- SSH client on CachyOS host (`sshpass` installed for password auth)

### Step 1: Create Incus VM

On the CachyOS host (192.168.1.191):

```bash
# Launch VM with Windows 11 compatible settings
incus launch win11 --vm \
  -c limits.cpu=4 \
  -c limits.memory=8Gi \
  -d root,size=80Gi \
  -d rootio.write-speed=100MB \
  -d rootio.read-speed=100MB

# Verify network assignment
incus list win11
```

Confirm the VM gets IP 10.136.57.35 on the Incus bridge.

### Step 2: Install Windows 11

1. Attach the Windows 11 ISO via Incus console
2. Complete the standard Windows 11 Pro installation
3. Create user account: `wyatt` / `Yy26689960*`
4. Enable Remote Desktop (optional, for GUI access)
5. Set DNS on Ethernet adapter to `8.8.8.8` and `1.1.1.1` manually (the Incus bridge does not provide internet DNS)

### Step 3: Enable Containers Feature

Open PowerShell as Administrator:

```powershell
Install-WindowsFeature -Name Containers -Restart
```

Reboot when prompted.

### Step 4: Install Docker CE

```powershell
# Download Docker CE installer
Invoke-WebRequest -Uri "https://download.docker.com/win/static/stable/x86_64/docker-27.5.1.zip" -OutFile "C:\docker.zip"

# Extract
Expand-Archive -Path "C:\docker.zip" -DestinationPath "C:\" -Force

# Add to PATH
$env:Path += ";C:\docker"
[Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\docker", "Machine")

# Register and start Docker service
dockerd --register-service --service-name "docker"
Start-Service docker

# Switch to Windows containers mode (critical: this runner uses Windows containers)
# If Docker installs in Linux containers mode, switch via the system tray or:
& "C:\Program Files\Docker\Docker\DockerCli.exe" -SwitchWindowsEngine
```

Verify:

```powershell
docker info
# Confirm: "OSType: windows"
```

### Step 5: Install Forgejo Runner

```powershell
# Download the runner binary (Crown0815 GitHub mirror, v12.10.1)
# Place at C:\forgejo-runner\forgejo-runner.exe

# Create the runner directory
New-Item -ItemType Directory -Path "C:\forgejo-runner" -Force

# Copy the binary into C:\forgejo-runner\forgejo-runner.exe
# (Download from GitHub mirror or transfer from host)
```

### Step 6: Register the Runner

From the Forgejo instance, generate a runner registration token, then:

```powershell
cd C:\forgejo-runner
.\forgejo-runner.exe register --no-interactive \
  --name win11-runner \
  --instance https://your-forgejo-instance \
  --token <REGISTRATION_TOKEN> \
  --labels "windows-latest"
```

This generates `.runner` and `daemon.yml` files in `C:\forgejo-runner\`.

### Step 7: Install as NSSM Service

```powershell
# Download NSSM if not present
# Place nssm.exe at C:\forgejo-runner\nssm.exe (or add to PATH)

# Install the service
nssm install ForgejoRunner "C:\forgejo-runner\forgejo-runner.exe" "daemon"
nssm set ForgejoRunner AppDirectory "C:\forgejo-runner"
nssm set ForgejoRunner Start SERVICE_AUTO_START
nssm set ForgejoRunner AppStdout "C:\forgejo-runner\logs\service-stdout.log"
nssm set ForgejoRunner AppStderr "C:\forgejo-runner\logs\service-stderr.log"
nssm set ForgejoRunner AppRotateFiles 1
nssm set ForgejoRunner AppRotateBytes 10485760

# Start the service
nssm start ForgejoRunner
```

## 3. Configuration

### daemon.yml

Located at `C:\forgejo-runner\daemon.yml`. Key settings:

```yaml
app:
  # Forgejo instance URL
  forgejo_url: https://your-forgejo-instance

runner:
  # Docker configuration
  docker:
    # Must use named pipe for Docker on Windows
    network: "host"
    privileged: false
    workdir_parent: ""
    containerdockerhost: "npipe:////./pipe/docker_engine"

  # Labels this runner can handle
  labels:
    - "windows-latest"

  # Timeout for jobs (seconds)
  timeout: 3600
```

### .runner File

Located at `C:\forgejo-runner\.runner`. This is the runner identity and label configuration.

**Critical**: The `.runner` file must **NOT** contain a `"docker"` label. Only `"windows-latest"` is allowed. If `"docker"` is present, Forgejo will route Linux-based Docker jobs to this Windows runner, which will fail.

To verify:

```powershell
Get-Content 'C:\forgejo-runner\.runner' | ConvertFrom-Json | Select-Object -ExpandProperty labels
# Expected output: ["windows-latest"]
```

To update labels (PowerShell):

```powershell
$runner = Get-Content 'C:\forgejo-runner\.runner' | ConvertFrom-Json
$runner.labels = @("windows-latest")
$runner | ConvertTo-Json -Depth 10 | Set-Content 'C:\forgejo-runner\.runner'
```

### NSSM Service

| Setting | Value |
|---|---|
| Service name | ForgejoRunner |
| Binary | C:\forgejo-runner\forgejo-runner.exe |
| Arguments | daemon |
| Working directory | C:\forgejo-runner |
| Start type | SERVICE_AUTO_START |
| Stdout log | C:\forgejo-runner\logs\service-stdout.log |
| Stderr log | C:\forgejo-runner\logs\service-stderr.log |
| Log rotation | Enabled (10 MB) |

### Docker Configuration

- Mode: **Windows containers** (not Linux containers)
- Socket: `npipe:////./pipe/docker_engine`
- Containers feature must be enabled on Windows
- To switch modes: use the Docker system tray icon or `DockerCli.exe -SwitchWindowsEngine`

## 4. Operations

### Restart the Runner Service

```powershell
net stop ForgejoRunner && net start ForgejoRunner
```

Or via NSSM:

```powershell
nssm restart ForgejoRunner
```

### Check Runner Status

```powershell
nssm status ForgejoRunner
```

### Check Service Logs

```powershell
# Recent logs
Get-Content "C:\forgejo-runner\logs\service-stdout.log" -Tail 50
Get-Content "C:\forgejo-runner\logs\service-stderr.log" -Tail 50
```

### SSH Access from CachyOS Host

```bash
sshpass -p "Yy26689960*" ssh -o StrictHostKeyChecking=no wyatt@10.136.57.35
```

> **Note**: SSH key authentication does not work on this VM due to Windows admin group override redirecting `AuthorizedKeysFile`. Always use password auth via `sshpass`.

### Update Runner Binary

1. Stop the service:
   ```powershell
   net stop ForgejoRunner
   ```

2. Replace `C:\forgejo-runner\forgejo-runner.exe` with the new version.

3. Start the service:
   ```powershell
   net start ForgejoRunner
   ```

### Update Runner Labels

```powershell
$runner = Get-Content 'C:\forgejo-runner\.runner' | ConvertFrom-Json
$runner.labels = @("windows-latest")
$runner | ConvertTo-Json -Depth 10 | Set-Content 'C:\forgejo-runner\.runner'
```

Restart the service after updating labels:

```powershell
net stop ForgejoRunner && net start ForgejoRunner
```

### View Running Containers

```powershell
docker ps -a
```

### Clean Up Old Containers

```powershell
docker container prune -f
```

## 5. Troubleshooting

### SSH Key Auth Not Working

**Symptom**: `ssh wyatt@10.136.57.35` fails with public key denied, but password auth works.

**Cause**: Windows admin group membership overrides `AuthorizedKeysFile` settings, redirecting it away from the configured path.

**Resolution**: Use password auth via `sshpass`:

```bash
sshpass -p "Yy26689960*" ssh -o StrictHostKeyChecking=no wyatt@10.136.57.35
```

### DNS Not Working / No Internet

**Symptom**: VM cannot resolve hostnames, cannot download packages, cannot reach Forgejo instance by name.

**Cause**: The Incus bridge does not provide DNS. Windows defaults to obtaining DNS automatically, which fails.

**Resolution**: Set DNS manually on the Ethernet adapter:

```powershell
# Set primary DNS
netsh interface ip set dns "Ethernet" static 8.8.8.8

# Set secondary DNS
netsh interface ip add dns "Ethernet" 1.1.1.1 index=2
```

Or via GUI: Network Settings > Ethernet > Edit DNS settings > Manual > 8.8.8.8, 1.1.1.1.

### Docker Issues

**Docker daemon not running:**

```powershell
Start-Service docker
```

**Wrong container mode (Linux instead of Windows):**

```powershell
# Check current mode
docker info | Select-String "OSType"
# If "linux" instead of "windows":
& "C:\Program Files\Docker\Docker\DockerCli.exe" -SwitchWindowsEngine
```

**Docker socket not found:**

Ensure Docker is running and the Windows containers feature is enabled. The socket path is `npipe:////./pipe/docker_engine`.

### Runner Not Picking Up Tasks

1. Verify the service is running:
   ```powershell
   nssm status ForgejoRunner
   ```

2. Check that labels in `.runner` match what Forgejo workflows expect:
   ```powershell
   Get-Content 'C:\forgejo-runner\.runner' | ConvertFrom-Json | Select-Object -ExpandProperty labels
   ```

3. Verify the runner is connected to Forgejo by checking the Forgejo admin panel (Site Administration > Runners).

4. Check service logs for errors:
   ```powershell
   Get-Content "C:\forgejo-runner\logs\service-stderr.log" -Tail 50
   ```

5. Restart the service:
   ```powershell
   net stop ForgejoRunner && net start ForgejoRunner
   ```

### Accidentally Added "docker" Label

If the `.runner` file contains a `"docker"` label, Forgejo will route Linux Docker jobs to this Windows runner, which will fail.

**Fix**: Remove the docker label and restart:

```powershell
$runner = Get-Content 'C:\forgejo-runner\.runner' | ConvertFrom-Json
$runner.labels = @("windows-latest")
$runner | ConvertTo-Json -Depth 10 | Set-Content 'C:\forgejo-runner\.runner'
net stop ForgejoRunner && net start ForgejoRunner
```

### Runner Stops After Windows Update

Windows updates may restart the machine. The NSSM service is set to `SERVICE_AUTO_START`, so it should come back automatically. If not:

```powershell
nssm start ForgejoRunner
```

## 6. Maintenance

### Updating the Runner Binary

1. Download the latest release from the [Crown0815 GitHub mirror](https://github.com/Crown0815/forgejo-runner/releases)
2. Stop the service:
   ```powershell
   net stop ForgejoRunner
   ```
3. Replace `C:\forgejo-runner\forgejo-runner.exe`
4. Start the service:
   ```powershell
   net start ForgejoRunner
   ```
5. Verify status:
   ```powershell
   nssm status ForgejoRunner
   ```

### Updating Windows

1. Run Windows Update via Settings > Windows Update
2. Restart when prompted (NSSM service will auto-start after reboot)
3. After reboot, verify DNS is still set (Windows updates can sometimes reset network settings):
   ```powershell
   netsh interface ip show dns "Ethernet"
   ```
4. Verify Docker is running:
   ```powershell
   docker info
   ```
5. Verify runner service is running:
   ```powershell
   nssm status ForgejoRunner
   ```

### Updating Docker

1. Download the latest Docker CE zip from [Docker's static binaries](https://download.docker.com/win/static/stable/x86_64/)
2. Stop Docker:
   ```powershell
   Stop-Service docker
   ```
3. Replace files in `C:\docker\`
4. Start Docker:
   ```powershell
   Start-Service docker
   ```
5. Verify Windows containers mode:
   ```powershell
   docker info | Select-String "OSType"
   ```
6. Restart the runner service:
   ```powershell
   net stop ForgejoRunner && net start ForgejoRunner
   ```

### Regular Maintenance Checklist

- [ ] Check DNS settings after any Windows/network change
- [ ] Verify runner is connected in Forgejo admin panel
- [ ] Review service logs for recurring errors
- [ ] Clean up old Docker containers/images (`docker system prune`)
- [ ] Verify runner labels haven't drifted (should only be `["windows-latest"]`)
- [ ] Test SSH access from CachyOS host after any network change
