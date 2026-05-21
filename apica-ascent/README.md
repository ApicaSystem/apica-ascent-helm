---
description: >-
  Apica Ascent deployment on Kubernetes using HELM 3 with Envoy Gateway
---

# Apica Ascent - Kubernetes Deployment Guide

## Overview

Apica Ascent is a cloud-native observability platform that provides unified logging, monitoring, tracing, and analytics. This chart uses **Envoy Gateway v1.6.0** for modern standards-based ingress management.

## Architecture

This chart supports two deployment patterns using Envoy Gateway:

### Single-Namespace Deployment (Default)
```
┌──────────────────────────────────────────────────────┐
│    Namespace: envoy-gateway-system                   │
│  ┌────────────────────────────────────────────────┐  │
│  │     Envoy Gateway Controller                   │  │
│  │  (watches GatewayClass, Gateway, Routes)       │  │
│  └────────────────────┬───────────────────────────┘  │
└───────────────────────┼──────────────────────────────┘
                        │ manages
┌───────────────────────▼──────────────────────────────┐
│         Namespace: apica                             │
│                                                      │
│  ┌──────────────┐   ┌────────────────┐              │
│  │ GatewayClass │   │  EnvoyProxy    │              │
│  │  (apica-gc)  │◄──│   Config       │              │
│  └──────┬───────┘   └────────────────┘              │
│         │                                            │
│  ┌──────▼───────┐                                   │
│  │   Gateway    │                                   │
│  │ (apica-gw)   │                                   │
│  └──────┬───────┘                                   │
│         │                                            │
│  ┌──────▼───────┐   ┌────────────────┐              │
│  │  HTTPRoute   │   │   TCPRoute     │              │
│  │              │   │                │              │
│  └──────┬───────┘   └────┬───────────┘              │
│         │                │                          │
│  ┌──────▼────────────────▼───────────┐              │
│  │     Backend Services              │              │
│  │  (flash, coffee, prometheus...)   │              │
│  └───────────────────────────────────┘              │
└──────────────────────────────────────────────────────┘
```

**Characteristics:**
- One GatewayClass per namespace
- One Gateway per release
- All resources use `{{ .Release.Name }}` prefix
- Isolated per namespace
- Recommended for single-tenant deployments

### Multi-Namespace Deployment
```
┌──────────────────────────────────────────────────────┐
│    Namespace: envoy-gateway-system                   │
│  ┌────────────────────────────────────────────────┐  │
│  │     Envoy Gateway Controller                   │  │
│  │  (watches all GatewayClasses & Gateways)       │  │
│  └────────┬───────────────────┬───────────────────┘  │
└───────────┼───────────────────┼──────────────────────┘
            │ manages           │ manages
┌───────────▼──────────────┐ ┌──▼──────────────────────┐
│  Namespace: apica-prod   │ │  Namespace: apica-dev   │
│  ┌──────────────┐        │ │  ┌──────────────┐       │
│  │ GatewayClass │        │ │  │ GatewayClass │       │
│  │(apica-prod-gc│◄─┐     │ │  │(apica-dev-gc)│◄─┐    │
│  └──────┬───────┘  │     │ │  └──────┬───────┘  │    │
│         │   ┌──────┴────┐│ │         │   ┌──────┴───┐│
│  ┌──────▼───┤EnvoyProxy ││ │  ┌──────▼───┤EnvoyProxy││
│  │ Gateway  │  Config   ││ │  │ Gateway  │  Config  ││
│  │(prod-gw) └───────────┘│ │  │(dev-gw)  └──────────┘│
│  └──────┬───────┐        │ │  └──────┬───────┐       │
│  ┌──────▼───┐   │        │ │  ┌──────▼───┐   │       │
│  │HTTPRoute │   │        │ │  │HTTPRoute │   │       │
│  └──────┬───┘   │        │ │  └──────┬───┘   │       │
│  ┌──────▼───────▼──────┐ │ │  ┌──────▼───────▼─────┐ │
│  │  Backend Services   │ │ │  │  Backend Services  │ │
│  └─────────────────────┘ │ │  └────────────────────┘ │
└──────────────────────────┘ └─────────────────────────┘
```

**Characteristics:**
- Independent GatewayClass per namespace
- Separate Gateway per environment
- Different cloud provider configs per namespace
- Full isolation between deployments
- Recommended for multi-tenant or multi-environment setups

**Key Components:**
1. **GatewayClass** - Defines controller and links to EnvoyProxy config
2. **EnvoyProxy** - Contains service type and cloud provider annotations
3. **Gateway** - Actual gateway instance with listeners (HTTP/HTTPS/TCP)
4. **Routes** - HTTPRoute and TCPRoute for traffic routing

## 1 - Prerequisites

- Kubernetes cluster version >= 1.30.0
- HELM 3 installed
- kubectl configured to access your cluster
- **Envoy Gateway v1.6.0** (required)

### Install envoy-gateway-system CRDs

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.6.0 \
  -n envoy-gateway-system \
  --create-namespace
```

**Reference**: https://gateway.envoyproxy.io/docs/install/install-helm/

> **Note**: The Envoy Gateway chart creates CRDs and the controller, but NOT the GatewayClass or Gateway resources. Those are created by the Apica Ascent chart.
>
> **CNPG support:** This chart can create CloudNativePG `Cluster` resources when `cnpg.enabled` is set to `true` in `values.yaml`.
>
> **Migrating from Bitnami Postgres to CNPG:**
> 1. Keep `global.chart.postgres: true` so the existing Bitnami Postgres stays running alongside the new CNPG cluster.
> 2. Set `cnpg.migration.enabled: true`. The CNPG cluster will bootstrap itself by importing from the source using `pg_dump`/`pg_restore` (managed natively by the CNPG operator — no separate Job is required). Configure `cnpg.migration.source` to point at the existing Postgres service. By default `type: monolith` imports all databases and roles; set `type: microservice` to import a single database.
> 3. Once the CNPG cluster is healthy, update `global.environment.postgres_host`, `postgres_user`, and `postgres_password` to point at the CNPG service (the cluster name or `cnpg.service.host`), then set `cnpg.migration.enabled: false`.
> 4. Set `global.chart.postgres: false` to remove the old Bitnami Postgres.
>
Please read and agree to the [EULA](https://docs.apica.ai/eula/eula) before proceeding.

### 1.1 Add Ascent helm repository

```bash
helm repo add apica-repo https://github.com/ApicaSystem/apica-ascent-helm
helm repo update
```

> The HELM repository will be named `apica-repo`. For installing charts from this repository please make sure to use the repository name as the prefix e.g.
> 
> `helm install <deployment_name> apica-repo/<chart_name>`
>

You can now run `helm search repo apica-repo` to see the available helm charts

```bash
$ helm search repo apica-repo
NAME                CHART VERSION        APP VERSION                     DESCRIPTION
apica-repo/apica    apica-ascent-3.0.0    v3.10.2      Ascent Observability for Kubernetes
```

### 1.2 Create namespace where Ascent will be deployed

> NOTE: Namespace name cannot be more than 15 characters in length

```bash
kubectl create namespace apica
```

This will create a namespace **`apica`** where we will deploy the Ascent Log Insights stack.

> If you choose a different name for the namespace, please remember to use the same namespace for the remainder of the steps

### 1.3 Prepare your Values YAML file

Sample YAML files for small, medium, large cluster configs can be downloaded at the links below

[Ascent Sample Values.yaml files](https://docs.logiq.ai/deploying-apica-data-fabric/logiq-paas-deployment#prepare-your-values-file)

These YAML files can be used for deployment with -f parameter as shown below in the description.

```bash
helm install apica --namespace apica \
--set global.persistence.storageClass=<storage class name> apica-repo/apica -f values.small.yaml
```
Please refer [Section 3.10 ](k8s-quickstart-guide.md#3-10-sizing-your-Ascent-cluster) for sizing your Ascent cluster as specified  in these yaml files.

## 2. Install Ascent

```bash
helm install apica --namespace apica \
--set global.persistence.storageClass=<storage class name> apica-repo/apica
```

This will install Ascent and expose the Ascent services and UI via Envoy Gateway. Service ports are described in the [Port details section](https://docs.apica.ai/apica-server/quickstart-guide#ports). You should now be able to go to `http://gateway-ip/`

> The default login and password to use is `flash-admin@foo.com` and `flash-password`. You can change these in the UI once logged in. Helm chart can override the default admin settings as well. See section[ 3.7](k8s-quickstart-guide.md#3-7-customize-admin-account) on customizing the admin settings

![Apica Ascent Login UI ](https://4019754726-files.gitbook.io/~/files/v0/b/gitbook-x-prod.appspot.com/o/spaces%2F-LmzGprckLqwd5v6bs6m%2Fuploads%2FJUfoTuyiUlzfAlAcTmEY%2FScreen%20Shot%202024-02-14%20at%2010.55.14%20AM.png?alt=media&token=d5ce1e9f-70e6-4a50-8bb3-0f8b0e4191cd)

Ascent server provides Ingest, log tailing, data indexing, query and search capabilities.  
Besides the web based UI, Ascent also offers [apicactl, Ascent CLI](https://docs.apica.ai/apica-cli) for accessing the above features.

## 3 Customizing the deployment

### 3.1 Enabling HTTPS for the UI

Create a TLS secret with your certificate:

```bash
kubectl create secret tls apica-tls \
  --cert=path/to/tls.crt \
  --key=path/to/tls.key \
  -n apica
```

Install with HTTPS enabled:

```bash
helm install apica --namespace apica \
--set global.domain=apica.my-domain.com \
--set gateway.tls.enabled=true \
--set gateway.tls.secretName=apica-tls \
--set global.persistence.storageClass=<storage class name> apica-repo/apica
```

> Access the UI at `https://apica.my-domain.com` after updating your DNS to point to the Gateway IP

| HELM Option | Description | Default |
| :--- | :--- | :--- |
| `global.domain` | DNS domain for the Apica Ascent service | No default |
| `gateway.tls.enabled` | Enable HTTPS on the Gateway | false |
| `gateway.tls.secretName` | Name of the TLS Secret (must be in same namespace) | No default |
| `envoyGateway.enabled` | Enable Envoy Gateway (required) | true |

### 3.2 Using an AWS S3 bucket

Depending on your requirements, you may want to host your storage in your own K8S cluster or create a bucket in a cloud provider like AWS.

> Please note that cloud providers may charge data transfer costs between regions. It is important that the Ascent cluster be deployed in the same region where the S3 bucket is hosted

#### 3.2.1 Create an access/secret key pair for creating and managing your bucket <a id="3-1-1"></a>

Go to AWS IAM console and create an access key and secret key that can be used to create your bucket and manage access to the bucket for writing and reading your log files

#### 3.2.2 Deploy the Ascent helm in gateway mode

Make sure to pass your `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` and give a bucket name. The S3 gateway acts as a caching gateway and helps reduce API costs.  
Create a bucket in AWS s3 with a unique bucket name in the region where you plan to host the deployment.

> You do not need to create the bucket, we will automatically provision it for you. Just provide the bucket name and access credentials in the step below.
>
> If the bucket already exists, Ascent will use it. Check to make sure the access and secret key work with it. Additionally, provide a valid amazon service endpoint for s3 else the config defaults to [https://s3.us-east-1.amazonaws.com](https://s3.us-east-1.amazonaws.com)

```bash
helm install apica --namespace apica --set global.domain=apica.my-domain.com \
--set global.environment.s3_bucket=<bucket_name> \
--set global.environment.awsServiceEndpoint=https://s3.<region>.amazonaws.com \
--set global.environment.AWS_ACCESS_KEY_ID=<access_key> \
--set global.environment.AWS_SECRET_ACCESS_KEY=<secret_key> \
--set global.persistence.storageClass=<storage class name> apica-repo/apica
```

| HELM Option | Description | Defaults |
| :--- | :--- | :--- |
| `global.environment.s3_bucket` | Name of the S3 bucket in AWS | apica |
| `global.environment.awsServiceEndpoint` | S3 Service endpoint : [https://s3.\*\*&lt;region&gt;\*\*.amazonaws.com](https://s3.**<region>**.amazonaws.com) | [https://s3.us-east-1.amazonaws.com](https://s3.us-east-1.amazonaws.com) |
| `global.environment.AWS_ACCESS_KEY_ID` | AWS Access key for accessing the bucket | No default |
| `global.environment.AWS_SECRET_ACCESS_KEY` | AWS Secret key for accessing the bucket | No default |
| `global.environment.s3_region` | AWS Region where the bucket is hosted | us-east-1 |

> S3 providers may have restrictions on bucket names for e.g. AWS S3 bucket names are globally unique.

### 3.3 Install Ascent server certificates and Client CA `[OPTIONAL]`

Ascent supports TLS for all ingest. We also enable non-TLS ports by default. It is however recommended that non-TLS ports not be used unless running in a secure VPC or cluster. The certificates can be provided to the cluster using K8S secrets. Replace the template sections below with your Base64 encoded secret files.

> If you skip this step, the Ascent server automatically generates a ca and a pair of client and server certificates for you to use. you can get them from the ingest server pods under the folder `/flash/certs`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: apica-certs
type: Opaque
data:
  ca.crt: CA goes here
  syslog.crt: Server certificate goes here
  syslog.key: Server certificate signing key goes here
```

Save the secret file e.g. `apica-certs.yaml`. Proceed to install the secret in the same namespace where you want to deploy Ascent

The secret can now be passed into the Ascent deployment

```bash
helm install apica --namespace apica --set global.domain=apica.my-domain.com \
--set apica-flash.secrets_name=apica-certs \
--set global.persistence.storageClass=<storage class name> apica-repo/apica
```

| HELM Option | Description | Defaults |
| :--- | :--- | :--- |
| `apica-flash.secrets_name` | TLS certificate key pair and CA cert for TLS transport | No default |

### 3.4 Changing the storage class

If you are planning on using a specific storage class for your volumes, you can customize it for the Ascent deployment. By default, Ascent uses the `standard` storage class

> It is quite possible that your environment may use a different storage class name for the provisioner. In that case please use the appropriate storage class name. E.g. if a user creates a storage class `ebs-volume` for the EBS provisioner for their cluster, you can use `ebs-volume` instead of `gp2` as suggested below

| Cloud Provider | K8S StorageClassName | Default Provisioner |
| :--- | :--- | :--- |
| AWS | gp3 | EBS |
| Azure | standard | azure-disc |
| GCP | standard | pd-standard |
| Digital Ocean | do-block-storage | Block Storage Volume |
| Oracle | oci | Block Volume |

```bash
helm upgrade --namespace apica \
--set global.persistence.storageClass=<storage class name> \
apica apica-repo/apica
```

### 3.5 Using external AWS RDS Postgres database instance

To use external AWS RDS Postgres database for your Ascent deployment, execute the following command.

```bash
helm install apica --namespace apica \
--set global.chart.postgres=false \
--set global.environment.postgres_host=<postgres-host-ip/dns> \
--set global.environment.postgres_user=<username> \
--set global.environment.postgres_password=<password> \
--set global.persistence.storageClass=<storage class name> apica-repo/apica
```

| HELM Option | Description | Default |
| :--- | :--- | :--- |
| `global.chart.postgres` | Deploy Postgres which is needed for Ascent metadata. Set this to false if an external Postgres cluster is being used | true |
| `global.environment.postgres_host` | Host IP/DNS for external Postgres | postgres |
| `global.environment.postgres_user` | Postgres admin user | postgres |
| `global.environment.postgres_password` | Postgres admin user password | postgres |
| `global.environment.postgres_port` | Host Port for external Postgres | 5432 |

> While configuring RDS, create a new parameter group that sets autoVaccum to true or the value "1", associate this parameter group to your RDS instance.
>
> Auto vacuum automates the execution of `VACUUM` and `ANALYZE` \(to gather statistics\) commands. Auto vacuum checks for bloated tables in the database and reclaims the space for reuse.

### 3.6 Upload Ascent professional license

The deployment described above offers 30 days trial license. Email `license@apica.ai` to obtain a professional license. After obtaining the license, use the apicactl tool to apply the license to the deployment. Please refer `apicactl` details at [https://apicactl.apica.ai/](https://apicactl.apica.ai/). You will need API-token from Ascent UI as shown below

![Apica Ascent Login Api-token ](https://github.com/logiqai/docs/raw/master/.gitbook/assets/Screen-Shot-2020-08-09-ALERT.png)

```bash
# Setup your Ascent Cluster endpoint
apicactl config set-cluster apica.my-domain.com

# Sets a apica ui api token
apicactl config set-token api_token

# Upload your Ascent deployment license
apicactl license set -l=license.jws

# View License information
apicactl license get
```

### 3.7 Customize Admin account

```bash
helm install apica --namespace apica \
--set global.environment.admin_name="Ascent Administrator" \
--set global.environment.admin_password="admin_password" \
--set global.environment.admin_email="admin@example.com" \
--set global.persistence.storageClass=<storage class name> apica-repo/apica
```

| HELM Option | Description | Default |
| :--- | :--- | :--- |
| `global.environment.admin_name` | Ascent Administrator name | flash-admin@foo.com |
| `global.environment.admin_password` | Ascent Administrator password | flash-password |
| `global.environment.admin_email` | Ascent Administrator e-mail | flash-admin@foo.com |

### 3.8 Using external Redis instance

To use external Redis for your Ascent deployment, execute the following command.

> NOTE: At this time Ascent only supports connecting to a Redis cluster in a local VPC without authentication

```bash
helm install apica --namespace apica \
--set global.chart.redis=false \
--set global.environment.redis_host=<redis-host-ip/dns> \
--set global.persistence.storageClass=<storage class name> apica-repo/apica
```

| HELM Option | Description | Default |
| :--- | :--- | :--- |
| `global.chart.redis` | Deploy Redis which is needed for log tailing. Set this to false if an external Redis cluster is being used | true |
| `global.environment.redis_host` | Host IP/DNS of the external Redis cluster | redis-master |
| `global.environment.redis_port` | Host Port where external Redis service is exposed | 6379 |

### 3.9 Configuring cluster id

When deploying Ascent, configure the cluster id to monitor your own Ascent deployment. For details about the `cluster_id` refer to section [Managing multiple K8S clusters](agentless.md#managing-multiple-k-8-s-clusters-in-a-single-apica-instance)

```bash
helm install apica --namespace apica \
--set global.environment.cluster_id=<cluster id> \
--set global.persistence.storageClass=<storage class name> apica-repo/apica
```

| HELM Option | Description | Default |
| :--- | :--- | :--- |
| global.environment.cluster\_id | Cluster Id being used for the K8S cluster running Ascent. See Section on [Managing multiple K8S](agentless.md#managing-multiple-k-8-s-clusters-in-a-single-apica-instance) clusters for more details. | Ascent |

### 3.10 Sizing your Ascent cluster

When deploying Ascent, size your infrastructure to provide appropriate vcpu and memory requirements. We recommened the following minimum size for small. medium and large cluster specification from [Section 1.3 ](k8s-quickstart-guide.md#1-3-prepare-your-values-YAML-file) values yaml files.

| Ascent Cluster | vCPU| Memory | NodeCount |
| :--- | :--- | :--- | :--- |
| small | 12| 32 gb | 3 |
| medium  | 20| 56 gb | 5 |
| large  | 32| 88 gb | 8 |

### 3.11 Gateway Service Type Configuration

The Envoy Gateway service type can be configured:

```bash
helm install apica -n apica \
--set envoyGateway.envoyProxy.provider.service.type=LoadBalancer \
apica-repo/apica
```

**Supported service types:**
- `LoadBalancer` (default) - For cloud providers with load balancer support
- `NodePort` - For bare-metal, K3s, or custom load balancers
- `ClusterIP` - For internal-only access

**Cloud-specific configurations:**

For cloud-specific configurations, see the platform-specific values files:
- `values.aws.yaml` - AWS EKS with LoadBalancer
- `values.azure.yaml` - Azure AKS with LoadBalancer
- `values.oke.yaml` - Oracle Cloud (OKE) with NodePort + OCI annotations
- `values.k3s.yaml` - K3s with NodePort
- `values.microk8s.yaml` - MicroK8s with NodePort

### 3.12 Using Node Selectors

The Ascent stack deployment can be optimized using node labels and node selectors to place various components of the stack optimally

```bash
apica.ai/node=ingest
```

The node label `apica.ai/node` above can be used to control the placement of ingest pods for log data into ingest optimized nodes. This allows for managing cost and instance sizing effectively.

The various nodeSelectors are defined in the globals section of the values.yaml file

```bash
globals:
  nodeSelectors:
    enabled: true
    ingest: ingest
    infra: common
    other: common
    db: common
    cache: common
    ingest_sync: common
```

In the example above, there are two node selectors in use - `ingest` and `common`. 

> Node selectors are enabled by setting `enabled` to `true` for `globals.nodeSelectors`

### 3.13 Installing Thanos

The Ascent stack includes Thanos as part of the deployment as an optional component for larger deployments. To enable Thanos, follow the steps below

```bash
helm upgrade --install apica --namespace apica \
--set global.chart.thanos=true \ 
--set global.persistence.storageClass=<storage class name> apica-repo/apica
```

The Thanos instance is auto configured to use the configured object storage endpoints

## 4 Teardown

If and when you want to decommission the installation using the following commands

```bash
helm delete apica --namespace apica
helm repo remove apica-repo
kubectl delete namespace apica
```

If you followed installation steps in section 3.1 - Using an AWS S3 bucket, you may want to delete the s3 bucket that was specified at deployment time.
