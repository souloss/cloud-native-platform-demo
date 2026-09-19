# Security Notes

This repository is a local teaching/demo project, not a production deployment
package. The checked-in Kubernetes manifests intentionally contain throwaway
credentials so a fresh k3d cluster can start without extra provisioning.

Before using any part of this project outside a disposable workstation:

- replace every demo password, JWT secret, encryption key and ingestion key;
- disable Kite anonymous access and use an external identity provider;
- inject secrets through a managed secret store rather than Git or inline YAML;
- pin all images and Helm charts by reviewed release or digest;
- put the Gateway behind TLS, authentication, rate limits and network policy;
- use a supported storage class with backups and restore tests for stateful data.

Do not report the local demo credentials as a vulnerability. Report accidentally
committed real credentials or a reproducible security issue through the private
channel configured by the repository owner.
