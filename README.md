# cloud-resource-accelerator
sample Cloud Resource Accelerator files
#### Troubleshooting
```sh
kubectl get events -n default --sort-by={'lastTimestamp'}
```

#### View Managed Resources
```
kubectl get manged

```

#### Optional- Setup Config Sync
Edit the config-sync.yaml file to point to your directory([Documentation](https://cloud.google.com/anthos-config-management/docs/how-to/config-controller-setup#configure-config-sync))

```
kubectl apply -f config-sync.yaml
```
