FROM mysql:5.7
MAINTAINER Nguyen Sy Thanh Son

COPY run.sh /run.sh

ENV REPLICATION_MASTER=**False** \
    REPLICATION_SLAVE=**False** \
    REPLICATION_USER=replica \
    REPLICATION_PASS=replica

EXPOSE 3306
CMD ["/run.sh"]
