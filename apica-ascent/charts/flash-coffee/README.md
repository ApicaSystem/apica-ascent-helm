* build
  - to run this helm chart, please configure values in values.yaml
    * there are few base64* values you can configure to test without flash-server
          
  - helm tips:
    * minikube start --bootstrapper=localkube --cpus 4 --memory 10124 --disk-size 90g
    * eval $(minikube docker-env)
    * minikube ssh
      sudo ip link set docker0 promisc on
  - monitoring via kubernetes:
    * prom1-operator.yaml
    # Define persistent storage for Prometheus (PVC)

* helm commands:
  helm dependency update
  helm install .