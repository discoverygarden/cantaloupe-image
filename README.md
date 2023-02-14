# README

example:
```
docker run -d -e TOMCAT_MEM=3g -v /opt/cantaloupe_configs/actual.info.yaml:/opt/cantaloupe_configs/info.yaml -p 8080:8080 cantaloupe:4.1.9-tomcat
```

verify:
```
curl http://localhost:8080/cantaloupe/iiif/2
```
