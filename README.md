# README

example:
```
docker run -d -e CANTALOUPE_MEM=3g -v /opt/cantaloupe_configs/actual.info.yaml:/opt/cantaloupe_configs/info.yaml -p 8080:8080 cantaloupe:{whatever image tag}
```

verify:
```
curl http://localhost:8080/iiif/2
```
