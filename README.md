# TailScale Exit Node Azure Builder Script

## Options
### List Regions
Lists available regions
```bash
./tsbuild.sh --list regions
```
### List VMs
List provisioned vms
```bash
./tsbuild.sh --list vms
```
### Build VM
Creates a new vm with tsuser account
```bash
./tsbuild.sh --build -h [HOSTNAME] -r [REGION] [--ssh-key /path/to/key.pub]"
```
> Note: TailScale Key is requested at execution
