This repository is base on [Docker Mysql official image](https://github.com/docker-library/mysql/) and [tutum-docker-mysql](https://github.com/tutumcloud/mysql).

Beside building a Mysql Docker Image, You are also able to create Mysql Master-Slave Replication

### Run Mysql Container
```
docker run --name some-mysql -e MYSQL_ROOT_PASSWORD=my-secret-pw -d thanhson1085/docker-mysql-replication:5.7
```
### Try Mysql Replication
- Clone this source code
- Enter command `docker-compose up`
