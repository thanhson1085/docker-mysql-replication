#!/bin/bash
set -eo pipefail
shopt -s nullglob

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
	set -- mysqld "$@"
fi

# skip setup if they want an option that stops mysqld
wantHelp=
for arg; do
	case "$arg" in
		-'?'|--help|--print-defaults|-V|--version)
			wantHelp=1
			break
			;;
	esac
done

_datadir() {
	"$@" --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }'
}

CONF_FILE="/etc/mysql/mysql.conf.d/mysqld.cnf"

# Set MySQL REPLICATION - MASTER
if [ -n "${REPLICATION_MASTER}" ]; then
    echo "=> Configuring MySQL replication as master (1/2) ..."
    if [ ! -f /tmp/replication_set.1 ]; then
        RAND="$(date +%s | rev | cut -c 1-2)$(echo ${RANDOM})"
        echo "=> Writting configuration file '${CONF_FILE}' with server-id=${RAND}"
        cat ${CONF_FILE} > /tmp/mysqld.cnf && \
            echo "bind-address = 0.0.0.0" >> /tmp/mysqld.cnf && \
            echo "server-id = ${RAND}" >> /tmp/mysqld.cnf && \
            echo "log-bin = mysql-bin" >> /tmp/mysqld.cnf && \
            mv /tmp/mysqld.cnf ${CONF_FILE}
        touch /tmp/replication_set.1
    else
        echo "=> MySQL replication master already configured, skip"
    fi
fi

# Set MySQL REPLICATION - SLAVE
if [ -n "${REPLICATION_SLAVE}" ]; then
    echo "=> Configuring MySQL replication as slave (1/2) ..."
    if [ -n "${MYSQL_PORT_3306_TCP_ADDR}" ] && [ -n "${MYSQL_PORT_3306_TCP_PORT}" ]; then
        if [ ! -f /tmp/replication_set.1 ]; then
            RAND="$(date +%s | rev | cut -c 1-2)$(echo ${RANDOM})"
            echo "=> Writting configuration file '${CONF_FILE}' with server-id=${RAND}"
            cat ${CONF_FILE} > /tmp/mysqld.cnf && \
                echo "bind-address = 0.0.0.0" >> /tmp/mysqld.cnf && \
                echo "server-id = ${RAND}" >> /tmp/mysqld.cnf && \
                echo "log-bin = mysql-bin" >> /tmp/mysqld.cnf && \
                mv /tmp/mysqld.cnf ${CONF_FILE}
            touch /tmp/replication_set.1
        else
            echo "=> MySQL replication slave already configured, skip"
        fi
    else
        echo "=> Cannot configure slave, please link it to another MySQL container with alias as 'mysql'"
        exit 1
    fi
fi


# allow the container to be started with `--user`
if [ "$1" = 'mysqld' -a -z "$wantHelp" -a "$(id -u)" = '0' ]; then
	DATADIR="$(_datadir "$@")"
	mkdir -p "$DATADIR"
	chown -R mysql:mysql "$DATADIR"
	exec gosu mysql "$BASH_SOURCE" "$@"
fi

if [ "$1" = 'mysqld' -a -z "$wantHelp" ]; then
	# Get config
	DATADIR="$(_datadir "$@")"

	if [ ! -d "$DATADIR/mysql" ]; then
		if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			echo >&2 'error: database is uninitialized and password option is not specified '
			echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
			exit 1
		fi

		mkdir -p "$DATADIR"

		echo 'Initializing database'
		"$@" --initialize-insecure
		echo 'Database initialized'

		"$@" --skip-networking &
		pid="$!"

		mysql=( mysql --protocol=socket -uroot )

		for i in {30..0}; do
			if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
				break
			fi
			echo 'MySQL init process in progress...'
			sleep 1
		done
		if [ "$i" = 0 ]; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
			# sed is for https://bugs.mysql.com/bug.php?id=20545
			mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
		fi

		if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			MYSQL_ROOT_PASSWORD="$(pwgen -1 32)"
			echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
		fi
		"${mysql[@]}" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			--  or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;

			DELETE FROM mysql.user ;
			CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
			DROP DATABASE IF EXISTS test ;
			FLUSH PRIVILEGES ;
		EOSQL

		if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
			mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
		fi

		if [ "$MYSQL_DATABASE" ]; then
			echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
			mysql+=( "$MYSQL_DATABASE" )
		fi

		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | "${mysql[@]}"

			if [ "$MYSQL_DATABASE" ]; then
				echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"
			fi

			echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
		fi

        # Set MySQL REPLICATION - MASTER
        if [ -n "${REPLICATION_MASTER}" ]; then
            echo "=> Configuring MySQL replication as master (2/2) ..."
            if [ ! -f /tmp/replication_set.2 ]; then
                echo "=> Creating a log user ${REPLICATION_USER}:${REPLICATION_PASS}"
                # delete user if exists
                mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "DELETE FROM mysql.user WHERE User = '${REPLICATION_USER}'" && \
                    mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "FLUSH PRIVILEGES" && \
                    mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "CREATE USER '${REPLICATION_USER}'@'%' IDENTIFIED BY '${REPLICATION_PASS}'"
                mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "GRANT REPLICATION SLAVE ON *.* TO '${REPLICATION_USER}'@'%'"
                mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "reset master"
                echo "=> Done!"
                touch /tmp/replication_set.2
            else
                echo "=> MySQL replication master already configured, skip"
            fi
        fi

        # Set MySQL REPLICATION - SLAVE
        if [ -n "${REPLICATION_SLAVE}" ]; then
            echo "=> Configuring MySQL replication as slave (2/2) ..."
            if [ -n "${MYSQL_PORT_3306_TCP_ADDR}" ] && [ -n "${MYSQL_PORT_3306_TCP_PORT}" ]; then
                if [ ! -f /tmp/replication_set.2 ]; then
                    echo "=> Setting master connection info on slave"
                    mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "stop slave"
                    until mysql -h${MYSQL_PORT_3306_TCP_ADDR} -P${MYSQL_PORT_3306_TCP_PORT} -u${MYSQL_ENV_REPLICATION_USER} -p${MYSQL_ENV_REPLICATION_PASS} -e "status" 2> /dev/null; do
                        echo "=> MYSQL MASTER is unavailable - sleeping"
                        sleep 1
                    done
                    echo "=> MYSQL MASTER status is OK!!!"
                    mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "CHANGE MASTER TO MASTER_HOST='${MYSQL_PORT_3306_TCP_ADDR}',MASTER_USER='${MYSQL_ENV_REPLICATION_USER}',MASTER_PASSWORD='${MYSQL_ENV_REPLICATION_PASS}',MASTER_PORT=${MYSQL_PORT_3306_TCP_PORT}, MASTER_CONNECT_RETRY=30"
                    mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "start slave"
                    echo "=> Done!"
                    touch /tmp/replication_set.2
                else
                    echo "=> MySQL replication slave already configured, skip"
                fi
            else
                echo "=> Cannot configure slave, please link it to another MySQL container with alias as 'mysql'"
                exit 1
            fi
        fi

		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)     echo "$0: running $f"; . "$f" ;;
				*.sql)    echo "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
				*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
				*)        echo "$0: ignoring $f" ;;
			esac
			echo
		done

		if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
			"${mysql[@]}" <<-EOSQL
				ALTER USER 'root'@'%' PASSWORD EXPIRE;
			EOSQL
		fi
		if ! kill -s TERM "$pid" || ! wait "$pid"; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		echo
		echo 'MySQL init process done. Ready for start up.'
		echo
	fi
fi

exec "$@"
