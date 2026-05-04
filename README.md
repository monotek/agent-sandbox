# agent-sandbox

A Docker / Podman agent sandbox using Mise.

## build

```bash
docker build . -t agent-sandbox
```

## run

Examples mounts the gitrepos dir in your hoem directory in the container. 
It also uses a readonmly scoped kubeconfig from ~/agent-sandbox/.kube to mount in to the agent home.

```bash
docker run -it --rm -v ~/gitrepos:/home/agent/gitrepos -v ~/agent-sandbox/.kube:/home/agent/.kube agent-sandbox
```
