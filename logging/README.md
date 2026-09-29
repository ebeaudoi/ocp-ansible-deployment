**Openshift Logging Stack with Taint and Tolerations**

This document will outline how to build a Logging monitoring stack in Red Hat Openshift using OC Kustomize and GitOps

_Scope:_
- Downloading required operators such Loki, Logging, Cluster Observability(COO)
- Creating tainted nodes
- Instantiating Loki and Logging instances

**Prereqs**

- Loki, Logging and Cluster Observability Operator(s)
- Object Storage (MINIO is used for this stack)
- Appropriate block storage 

**Create tainted nodes**

We will configure each instance to run on tainted infra nodes as to not utilize client node resources.

Create a yaml file with the following:

```
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  annotations:
    machine.openshift.io/memoryMb: "32768"
    machine.openshift.io/vCPU: "16"
  labels:
    machine.openshift.io/cluster-api-cluster: os4-kz768
    machine.openshift.io/cluster-api-machine-role: infra
    machine.openshift.io/cluster-api-machine-type: infra
  name: os4-kz768-logging
  namespace: openshift-machine-api
  uid: 4e6cea88-ec68-44fb-957e-c892fcf40a4f
spec:
  replicas: 3
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: os4-kz768
      machine.openshift.io/cluster-api-machineset: os4-kz768-logging
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-cluster: os4-kz768
        machine.openshift.io/cluster-api-machine-role: infra
        machine.openshift.io/cluster-api-machine-type: infra
        machine.openshift.io/cluster-api-machineset: os4-kz768-logging
    spec:
      lifecycleHooks: {}
      metadata: 
        labels:
          node-role.kubernetes.io/infra: ""
      providerSpec:
        value:
          apiVersion: machine.openshift.io/v1
          bootType: ""
          categories: null
          cluster:
            type: uuid
            uuid: 0006065e-1275-d982-04b4-88e9a47866b0
          credentialsSecret:
            name: nutanix-credentials
          dataDisks: null
          failureDomain: null
          gpus: null
          image:
            name: os4-kz768-rhcos
            type: name
          kind: NutanixMachineProviderConfig
          memorySize: 32Gi
          metadata:
            CreationTimestamp: null
          project:
            type: ""
          subnets:
          - type: uuid
            uuid: 318f3e2d-5e4d-44ac-9783-0a636c90dcfa
          systemDiskSize: 120Gi
          userDataSecret:
            name: worker-user-data
          vcpuSockets: 8
          vcpusPerSocket: 2
      taints:
        - key: workload
          effect: NoSchedule
          value: loki
```


**Configure MinIO object storage**

1) Create bucket in MinIO
2) Create IAM policy with the following, if not already existing:

 ```
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::<bucket_name>"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:GetObjectTagging",
        "s3:PutObjectTagging"
      ],
      "Resource": "arn:aws:s3:::<bucket_name>/*"
    }
  ]
}
```


3)Create IAM user and add the policy created in Step 2 to the user 

4)Create an access key pair under the IAM user (it will be required later)

## LOKI KUSTOMIZE FILES
### Loki Operator Install
Create yaml files listed (1-6) and place them in a designated folder
1) namespace.yaml
```
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-operators-redhat 
  annotations:
    openshift.io/node-selector: ""
  labels:
    openshift.io/cluster-monitoring: "true" 
```


2) operatorgroup.yaml
```
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec: {} 
```


3) subscription.yaml
```
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable-6.3
  installPlanApproval: Automatic
  name: loki-operator
  source: cs-redhat-catalog
  sourceNamespace: openshift-marketplace
```


4) clusteradmin-group.yaml
```
kind: Group
apiVersion: user.openshift.io/v1
metadata:
  name: cluster-admin
users:
- admin
```


5) clusteradmin-group-rolebinding.yaml
```
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-admin-group
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: cluster-admin
```


6) kustomization.yaml
```
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- namespace.yaml
- subscription.yaml
- operatorgroup.yaml
- clusteradmin-group.yaml
- clusteradmin-group-rolebinding.yaml
```


In command line:

7) `oc kustomize ..`

8) `oc apply -k ..`

### Loki Instance 
1) extract minio certificate. 

in command line: 
`openssl s_client -connect aistor-api.apps.os4.devu.ca:443 -showcerts </dev/null 2>/dev/null | openssl x509 -out storage-ca.crt` 

Create the following yaml files (2-5) and put them in a designated folder:

2) create config map for minio certificate (loki-s3-ca-bundle.yaml)
```
apiVersion: v1
data:
  service-ca.crt: |
    -----BEGIN CERTIFICATE-----
    <certificate>
    -----END CERTIFICATE-----
    kind: ConfigMap
metadata:
  creationTimestamp: null
  name: loki-s3-ca-bundle
  namespace: openshift-logging
```


3) create minio secret with access key made earlier (logging-loki-s3.yaml)
```
apiVersion: v1
data:
  access_key_id: <access_key_id>
  access_key_secret: <secret_access_key>
  bucketnames: <bucket_name>
  endpoint: <your_s3_endpoint>
  forcepathstyle: true
kind: Secret
metadata:
  creationTimestamp: null
  name: logging-loki-s3
  namespace: openshift-logging
```

4) create logging instance with Tolerations (03-loki-cr.yaml) 
```
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki 
  namespace: openshift-logging
spec:
  managementState: Managed
  limits:
    global:  
      retention:  
        days: 14
  size: 1x.pico 
  storage:
    schemas:
      - effectiveDate: '2026-06-15'
        version: v13
    secret:
      name: logging-loki-s3 
      type: s3 
    tls:
      caName: loki-s3-ca-bundle
  storageClassName: nutanix-volume 
  tenants:
    mode: openshift-logging
  template:
    compactor:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: workload
        value: loki
    distributor:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: workload
        value: loki
    gateway:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: workload
        value: loki
    indexGateway:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: workload
        value: loki
    ingester:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: workload
        value: loki
    querier:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: workload
        value: loki
    queryFrontend:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: workload
        value: loki
    ruler:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - effect: NoSchedule
        key: workload
        value: loki
```


5) kustomization.yaml
```
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - loki-s3-ca-bundle.yaml
  - logging-loki-s3.yaml 
  - 03-loki-cr.yaml
```


In command line:

6) `oc kustomize ..`

7) `oc apply -k ..`

## LOGGING KUSTOMIZE FILES
### Logging Operator Install

Create the following yaml files (1-4) and put them in a designated folder:
1) namespace.yaml
```
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-logging
  labels:
    openshift.io/cluster-monitoring: "true"
  annotations:
    openshift.io/display-name: Red Hat Logging
```


2) operator-group.yaml
```
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  targetNamespaces: 
    - openshift-logging
```


3) subscription.yaml
```
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  channel: stable-6.3
  installPlanApproval: Automatic
  name: cluster-logging
  source: cs-redhat-catalog
  sourceNamespace: openshift-marketplace
```


4) kustomization.yaml
```
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
  - operator-group.yaml
  - subscription.yaml
```


In command line: 

5) `oc kustomize ..`
6) `oc apply -k ..`

### Logging Instance 

Create the following yaml files (1-6) and put them in a designated folder:
1) loggingsa.yaml (this is to make a service account)
```
apiVersion: v1
kind: ServiceAccount
metadata:
  name: logging-collector
  namespace: openshift-logging
```


2) loggingrbac.yaml
```
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: logging-collector-logs-writer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: logging-collector-logs-writer
subjects:
- kind: ServiceAccount
  name: logging-collector
  namespace: openshift-logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: collect-application-logs
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: collect-application-logs
subjects:
- kind: ServiceAccount
  name: logging-collector
  namespace: openshift-logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: collect-infrastructure-logs
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: collect-infrastructure-logs
subjects:
- kind: ServiceAccount
  name: logging-collector
  namespace: openshift-logging
```


3) manager-rbac.yaml
```
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: manager-rolebinding
roleRef:                                           
  apiGroup: rbac.authorization.k8s.io              
  kind: ClusterRole                                
  name: cluster-logging-operator                   
subjects:                                          
  - kind: ServiceAccount                           
    name: cluster-logging-operator                 
    namespace: openshift-logging 
```


4) cluster-log-fowarder.yaml
```
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: instance
  namespace: openshift-logging
spec:
  serviceAccount:
    name: logging-collector
  outputs:
  - name: lokistack-out
    type: lokiStack
    lokiStack:
      target:
        name: logging-loki
        namespace: openshift-logging
      authentication:
        token:
          from: serviceAccount
    tls:
      ca:
        key: service-ca.crt
        configMapName: openshift-service-ca.crt
  pipelines:
  - name: infra-app-logs
    inputRefs:
    - application
    - infrastructure
    outputRefs:
    - lokistack-out
```


5) clusterlogforwarder-editor-role.yaml
```
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: clusterlogforwarder-editor-role
rules:                                              
  - apiGroups:                                      
      - observability.openshift.io                  
    resources:                                      
      - clusterlogforwarders                        
    verbs:                                          
      - create                                      
      - delete                                      
      - get                                         
      - list                                        
      - patch                                       
      - update                                      
      - watch 
```


6) kustomization.yaml
```
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - loggingsa.yaml
  - loggingrbac.yaml
  - cluster-log-fowarder.yaml
  - manager-rbac.yaml
  - clusterlogforwarder-editor-role.yaml
```


In command line: 

7) `oc kustomize ..`

8) `oc apply -k ..`

## CLUSTER OBSERVABILITY OPERATOR FILES
Create the following yaml files (1-4) and put them in a designated folder:
1) namespace.yaml
```
apiVersion: v1
kind: Namespace
metadata:
  labels:
    kubernetes.io/metadata.name: openshift-cluster-observability-operator
    openshift.io/cluster-monitoring: "true"
  name: openshift-cluster-observability-operator
```
 

2) coo-operator.yaml
```
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: openshift-cluster-observability-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: cluster-observability-operator
  source: cs-redhat-catalog
  sourceNamespace: openshift-marketplace
```


3) logging-plugin.yaml
```
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: logging
spec:
  type: Logging
  logging:
    lokiStack:
      name: logging-loki
    logsLimit: 50
    timeout: 30s
    schema: otel
```


4) kustomization.yaml
```
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
  - coo-operator.yaml
  - logging-plugin.yaml
```


In command line: 

5) `oc kustomize ..`

6) `oc apply -k ..`
