# mirrord demo on kind

A minimal Spring Boot demo for learning how to use `mirrord` with a Kubernetes-hosted service and database.

## Architecture

```
  Your laptop
  ┌────────────────────────────────────────────────────┐
  │                                                    │
  │  $ make run-local                                  │
  │  ┌──────────────────────────────┐                  │
  │  │  Local Java process          │                  │
  │  │  (Spring Boot :8080)         │◄── curl :8080    │
  │  │                              │                  │
  │  │  mirrord agent               │                  │
  │  └──────────┬───────────────────┘                  │
  │             │  intercepts DB calls                 │
  │             │  + steals matching HTTP requests     │
  └─────────────┼────────────────────────────────────-─┘
                │ mirrord tunnels to pod
  kind cluster  │
  ┌─────────────▼────────────────────────────────────-─┐
  │                                                    │
  │  namespace: mirrord-demo                           │
  │  ┌─────────────────┐     ┌──────────────────────┐  │
  │  │  mirrord-demo   │     │  mysql               │  │
  │  │  Deployment     │────►│  Deployment :3306    │  │
  │  │  NodePort 30080 │     └──────────────────────┘  │
  │  └────────┬────────┘                               │
  └───────────┼────────────────────────────────────────┘
              │ kind port mapping
  curl :18080 ▼
  127.0.0.1:18080
```

What the demo proves:

1. A local process can read and write the **in-cluster MySQL** database through mirrord.
2. Requests carrying `x-mirrord-mode: steal` are **stolen** to the local process; all other requests continue hitting the in-cluster pod.

## Prerequisites

| Tool | Install |
|------|---------|
| Docker | https://docs.docker.com/get-docker/ |
| kind | `brew install kind` |
| kubectl | `brew install kubectl` |
| Java 21+ | `brew install --cask temurin@21` |
| Maven | `brew install maven` |
| mirrord | `brew install metalbear-co/mirrord/mirrord` |

## Quick start

```bash
make deploy    # build image → load into kind → deploy MySQL + app
make validate  # run end-to-end assertions
```

## Local debug flow

```bash
make deploy      # one-time setup

make run-local   # start the app locally with mirrord
```

In a second terminal:

```bash
# 1. Confirm the local process responds (handledBy: local)
curl http://127.0.0.1:8080/api/messages/current

# 2. Write through the local process
curl -X POST \
  -H 'Content-Type: application/json' \
  -d '{"message":"updated through local"}' \
  http://127.0.0.1:8080/api/messages/current

# 3. Confirm the cluster sees the update (same MySQL, handledBy: cluster)
curl http://127.0.0.1:18080/api/messages/current

# 4. Send a steal-header request through the cluster NodePort — local handles it
curl -H 'x-mirrord-mode: steal' http://127.0.0.1:18080/api/messages/current
```

## All make targets

```
make help        Show available targets
make build       Compile and test (produces target/*.jar)
make deploy      Create kind cluster + build image + deploy k8s resources
make run-local   Run app locally with mirrord
make validate    Run end-to-end validation
make status      Show pod status in the demo namespace
make clean       Delete the kind cluster
```

## About header-based stealing on kind

The `.mirrord/mirrord.json` config steals only requests that carry `x-mirrord-mode: steal`:

```json
{
  "target": {
    "namespace": "mirrord-demo",
    "path": "deployment/mirrord-demo"
  },
  "feature": {
    "network": {
      "incoming": {
        "mode": "steal",
        "http_filter": {
          "header_filter": "^x-mirrord-mode: steal$"
        }
      }
    }
  }
}
```

The important detail is **how** the request enters the cluster.

- Use the NodePort exposed by kind on `http://127.0.0.1:18080`
- Do **not** use `kubectl port-forward` for the incoming-traffic part of the demo

`kubectl port-forward` bypasses the normal pod network path, so mirrord cannot intercept those requests. This repo uses a kind port mapping plus a NodePort service so incoming requests traverse the path mirrord hooks into.

## 中文说明：这个 demo 里 mirrord 怎么用

### Kubernetes cluster 需要做什么

在这个项目里，集群侧需要满足的条件很少，重点是 **要有一个可被 mirrord 附着的工作负载和一条真实的集群流量路径**：

1. `kubectl` 当前上下文能访问目标集群，并且有权限访问 `mirrord-demo` namespace。
2. 集群里已经部署了目标应用：`deployment/mirrord-demo`。
3. 集群里已经部署了应用依赖：这里是 `mysql.mirrord-demo.svc.cluster.local:3306`。
4. 需要让请求通过真实的 Service/NodePort 路径进入 Pod。这个 demo 使用 kind 的 `extraPortMappings` 把宿主机 `18080` 映射到 kind 节点 `30080`，再由 `NodePort 30080` 转发到应用 Pod。
5. 本地执行 `mirrord exec` 时，mirrord 会基于当前 kubeconfig 在集群里启动 `mirrord-agent` 并附着到目标 Pod，因此集群需要允许这一步正常完成。

换句话说，这个 demo **不需要你先手工在集群里安装一个应用内 SDK**，也不需要改 Spring Boot 代码；集群里只要有目标 Deployment、依赖服务、以及可访问的 Kubernetes API 即可。

### 本地需要执行什么命令

最直接的命令是：

```bash
make run-local
```

它最终执行的是：

```bash
mirrord exec -f .mirrord/mirrord.json -- \
  java \
  -Ddemo.app-instance=local \
  -Dspring.datasource.url='jdbc:mysql://mysql.mirrord-demo.svc.cluster.local:3306/mirrord_demo?createDatabaseIfNotExist=true&serverTimezone=UTC&useSSL=false&allowPublicKeyRetrieval=true' \
  -Dspring.datasource.username=demo \
  -Dspring.datasource.password=demo \
  -Dspring.sql.init.mode=never \
  -jar target/mirrord-demo-0.0.1-SNAPSHOT.jar
```

其中：

- `-f .mirrord/mirrord.json` 指定 mirrord 配置，里面声明了目标工作负载和 HTTP header 过滤规则。
- `--` 之后就是你原本想在本机运行的命令；这里仍然是一个普通的本地 Java 进程。
- 这个仓库应该把 `/.mirrord/mirrord.json` 提交到 git，因为它是项目共享配置，不是个人临时状态。

### 这个命令为什么能访问集群内 MySQL，又为什么能只劫持部分请求

根据 mirrord 官方文档，`mirrord exec` 做的事情不是“把你的应用部署到集群”，而是：

1. 在本机启动你的 Java 进程。
2. 用 `mirrord-layer` 注入到这个本地进程里，拦截底层网络/文件/环境变量相关系统调用。
3. 在集群目标 Pod 一侧启动 `mirrord-agent`，把这些调用转发到目标 Pod 的上下文里执行。

所以在这个 demo 里：

- **出站流量**：本地 Java 进程访问 `mysql.mirrord-demo.svc.cluster.local:3306` 时，连接不是走你本机网络，而是经由目标 Pod 的集群网络发出，因此可以直接访问集群内 MySQL。
- **入站流量**：`.mirrord/mirrord.json` 把 `feature.network.incoming.mode` 设成 `steal`，并配置了 `header_filter`，所以只有带 `x-mirrord-mode: steal` 的 HTTP 请求会被劫持到本地；其他请求仍由集群里的 Pod 正常处理。
- **为什么不能用 `kubectl port-forward` 验证 steal**：`port-forward` 走的是 API Server 隧道，不经过 mirrord hook 的那条 Pod 入站流量路径，所以这个 demo 才专门用 NodePort + kind 端口映射来验证请求劫持。

### 官方文档链接

- Introduction: <https://mirrord.dev/docs/overview/introduction/>
- Architecture: <https://mirrord.dev/docs/reference/architecture/>
- Network traffic / steal / header filter: <https://mirrord.dev/docs/reference/traffic/>

把这三篇对照起来看，就能理解这个项目的基本原理：

- Introduction 解释了 mirrord 是“让本地进程运行在云环境上下文里”。
- Architecture 解释了 `mirrord-cli`、`mirrord-layer`、`mirrord-agent` 三者如何协作。
- Traffic 文档解释了为什么这个 demo 里的 header-based stealing 能做到“只把带特定 header 的请求交给本地进程处理”。

## Scripts reference

The Makefile targets delegate to these scripts, which can also be run directly:

| Script | Purpose |
|--------|---------|
| `bash scripts/deploy-demo.sh` | Full cluster + app deployment |
| `bash scripts/run-local-with-mirrord.sh` | Run local app via mirrord |
| `bash scripts/validate-demo.sh` | End-to-end assertions |
