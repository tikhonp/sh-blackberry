# sh-blackberry — self-hosted blackberry node

Lenovo Thinkcenter m920q node with self-hosted services.o

> Including: `immich`, `copyparty`, `vaultwarden`

## Hardware

- Internal SSD on `/`
- External HDD for backups on `/mnt/seagate-backup`

## Running:

```bash
git clone --recurse-submodules git@github.com:tikhonp/sh-blackberry.git
cd sh-blackberry
docker compose up -d
```

# License

Tikhon Petrishchev 2025. All rights reserved.
